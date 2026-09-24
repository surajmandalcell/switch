import Foundation
import IOKit

enum FanControlMode: String, CaseIterable, Sendable {
  case automatic
  case cool
  case maximum

  var title: String {
    switch self {
    case .automatic: "Auto"
    case .cool: "Cool"
    case .maximum: "Max"
    }
  }
}

struct FanHardwareSample: Equatable, Sendable {
  let index: Int
  let actualRPM: Double
  let targetRPM: Double?
  let maximumRPM: Double
  let rawMode: UInt8?
}

struct FanSnapshot: Equatable, Sendable {
  let rpm: Int?
  let percent: Int?
  let mode: FanControlMode?
  let controlAvailable: Bool
  let message: String?
  let samples: [FanHardwareSample]

  static let loading = FanSnapshot(
    rpm: nil, percent: nil, mode: nil, controlAvailable: false,
    message: "Checking fan sensors…", samples: [])

  static func unavailable(_ message: String) -> FanSnapshot {
    FanSnapshot(
      rpm: nil, percent: nil, mode: nil, controlAvailable: false,
      message: message, samples: [])
  }

  init(samples: [FanHardwareSample], controlAvailable: Bool, message: String? = nil) {
    let displayed = samples.max { $0.actualRPM < $1.actualRPM }
    rpm = displayed.map { Int($0.actualRPM.rounded()) }
    percent = displayed.map {
      min(max(Int(($0.actualRPM / max($0.maximumRPM, 1) * 100).rounded()), 0), 100)
    }
    mode = Self.mode(for: samples)
    self.controlAvailable = controlAvailable
    self.message = message
    self.samples = samples
  }

  private init(
    rpm: Int?, percent: Int?, mode: FanControlMode?, controlAvailable: Bool,
    message: String?, samples: [FanHardwareSample]
  ) {
    self.rpm = rpm
    self.percent = percent
    self.mode = mode
    self.controlAvailable = controlAvailable
    self.message = message
    self.samples = samples
  }

  private static func mode(for samples: [FanHardwareSample]) -> FanControlMode? {
    guard !samples.isEmpty else { return nil }
    if samples.allSatisfy({ $0.rawMode == 0 }) { return .automatic }
    let targetRatios = samples.compactMap { sample -> Double? in
      guard let target = sample.targetRPM, sample.maximumRPM > 0 else { return nil }
      return target / sample.maximumRPM
    }
    guard targetRatios.count == samples.count else { return nil }
    if targetRatios.allSatisfy({ $0 >= 0.94 }) { return .maximum }
    if targetRatios.allSatisfy({ (0.52...0.68).contains($0) }) { return .cool }
    return nil
  }
}

enum FanControlError: LocalizedError {
  case helperUnavailable
  case noFans
  case invalidResponse
  case timedOut
  case service(String)

  var errorDescription: String? {
    switch self {
    case .helperUnavailable:
      "Install smctl and its daemon to enable fan control."
    case .noFans:
      "No controllable fans were found."
    case .invalidResponse:
      "The fan-control helper returned an invalid response."
    case .timedOut:
      "The fan-control helper did not respond."
    case .service(let message):
      message
    }
  }
}

actor MacFanService {
  static let refreshInterval = Duration.seconds(3)
  static let controlProbeInterval: TimeInterval = 15
  static let coolFraction = 0.60

  private var smc: FanSMCConnection?
  private var lastControlProbe: (date: Date, available: Bool)?

  func snapshot() -> FanSnapshot {
    do {
      let samples = try fanConnection().readFans()
      guard !samples.isEmpty else { throw FanControlError.noFans }
      let available = controlAvailable()
      return FanSnapshot(
        samples: samples,
        controlAvailable: available,
        message: available ? nil : FanControlError.helperUnavailable.localizedDescription)
    } catch {
      return .unavailable(error.localizedDescription)
    }
  }

  func apply(_ mode: FanControlMode) async throws -> FanSnapshot {
    let samples = try fanConnection().readFans()
    guard !samples.isEmpty else { throw FanControlError.noFans }
    let client = SMCtlClient()
    guard (try? client.capabilities().fanControlSupported) == true else {
      lastControlProbe = (Date(), false)
      throw FanControlError.helperUnavailable
    }

    do {
      switch mode {
      case .automatic:
        try client.setAuto()
      case .cool:
        for sample in samples {
          try client.setManual(
            fan: sample.index,
            rpm: sample.maximumRPM * Self.coolFraction)
        }
      case .maximum:
        try client.setProfile("full")
      }
    } catch {
      if mode == .cool { try? client.setAuto() }
      throw error
    }

    lastControlProbe = (Date(), true)
    try? await Task.sleep(for: .milliseconds(250))
    return FanSnapshot(samples: try fanConnection().readFans(), controlAvailable: true)
  }

  private func fanConnection() throws -> FanSMCConnection {
    if let smc { return smc }
    let connection = try FanSMCConnection()
    smc = connection
    return connection
  }

  private func controlAvailable(now: Date = Date()) -> Bool {
    if let cached = lastControlProbe,
       now.timeIntervalSince(cached.date) < Self.controlProbeInterval
    {
      return cached.available
    }
    let available = (try? SMCtlClient().capabilities().fanControlSupported) == true
    lastControlProbe = (now, available)
    return available
  }
}

// The AppleSMC ABI and decoding approach are adapted from smctl (MIT):
// https://github.com/leaperone/smctl
private final class FanSMCConnection {
  private static let selector: UInt32 = 2
  private static let commandReadValue: UInt8 = 5
  private static let commandReadKeyInfo: UInt8 = 9

  private var connection: io_connect_t = 0

  init() throws {
    guard MemoryLayout<SMCParam>.stride == 80 else { throw FanControlError.invalidResponse }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { throw FanControlError.service("AppleSMC is unavailable.") }
    defer { IOObjectRelease(service) }
    let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
    guard result == KERN_SUCCESS else {
      throw FanControlError.service("Could not open AppleSMC (\(result)).")
    }
  }

  deinit {
    if connection != 0 { IOServiceClose(connection) }
  }

  func readFans() throws -> [FanHardwareSample] {
    let count = (try? numericValue("FNum")).map { max(0, min(Int($0), 8)) }
      ?? (0..<8).prefix { (try? numericValue("F\($0)Ac")) != nil }.count
    return (0..<count).compactMap { index in
      guard let actual = try? numericValue("F\(index)Ac"),
            let maximum = try? numericValue("F\(index)Mx"), maximum > 0
      else { return nil }
      let mode = (try? readValue("F\(index)Md"))?.bytes.first
        ?? (try? readValue("F\(index)md"))?.bytes.first
      return FanHardwareSample(
        index: index,
        actualRPM: actual,
        targetRPM: try? numericValue("F\(index)Tg"),
        maximumRPM: maximum,
        rawMode: mode)
    }
  }

  private func numericValue(_ key: String) throws -> Double {
    let value = try readValue(key)
    let type = Set([fourCharacterString(value.info.dataType),
                    fourCharacterString(value.info.dataType.byteSwapped)])
    if type.contains("flt ") || type.contains("flt") {
      guard value.bytes.count >= 4 else { throw FanControlError.invalidResponse }
      let bits = UInt32(value.bytes[0]) | UInt32(value.bytes[1]) << 8
        | UInt32(value.bytes[2]) << 16 | UInt32(value.bytes[3]) << 24
      return Double(Float(bitPattern: bits))
    }
    if type.contains("fpe2") {
      guard value.bytes.count >= 2 else { throw FanControlError.invalidResponse }
      return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4
    }
    if type.contains("ui8 ") || type.contains("ui8") {
      guard let byte = value.bytes.first else { throw FanControlError.invalidResponse }
      return Double(byte)
    }
    throw FanControlError.invalidResponse
  }

  private func readValue(_ key: String) throws -> SMCValue {
    var infoInput = SMCParam()
    infoInput.key = try fourCharacterCode(key)
    infoInput.data8 = Self.commandReadKeyInfo
    let info = try call(infoInput).keyInfo

    var valueInput = SMCParam()
    valueInput.key = infoInput.key
    valueInput.keyInfo = info
    valueInput.data8 = Self.commandReadValue
    let value = try call(valueInput)
    return SMCValue(
      info: info,
      bytes: Array(withUnsafeBytes(of: value.bytes) { Array($0) }.prefix(Int(info.dataSize))))
  }

  private func call(_ input: SMCParam) throws -> SMCParam {
    var input = input
    var output = SMCParam()
    var outputSize = MemoryLayout<SMCParam>.stride
    let result = withUnsafePointer(to: &input) { inputPointer in
      withUnsafeMutablePointer(to: &output) { outputPointer in
        IOConnectCallStructMethod(
          connection, Self.selector, inputPointer, MemoryLayout<SMCParam>.stride,
          outputPointer, &outputSize)
      }
    }
    guard result == KERN_SUCCESS, output.result == 0 else {
      throw FanControlError.service("AppleSMC read failed.")
    }
    return output
  }
}

private typealias SMCBytes20 = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private typealias SMCBytes32 = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCVersion {
  var major: UInt8 = 0
  var minor: UInt8 = 0
  var build: UInt8 = 0
  var reserved: UInt8 = 0
}

private struct SMCKeyInfo {
  var dataSize: UInt32 = 0
  var dataType: UInt32 = 0
  var dataAttributes: UInt8 = 0
}

private struct SMCParam {
  var key: UInt32 = 0
  var version = SMCVersion()
  var limit: SMCBytes20 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  var keyInfo = SMCKeyInfo()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: SMCBytes32 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCValue {
  let info: SMCKeyInfo
  let bytes: [UInt8]
}

private func fourCharacterCode(_ string: String) throws -> UInt32 {
  let bytes = Array(string.utf8)
  guard bytes.count == 4 else { throw FanControlError.invalidResponse }
  return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
    | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

private func fourCharacterString(_ value: UInt32) -> String {
  [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
   UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    .map { $0 == 0 ? " " : String(UnicodeScalar($0)) }
    .joined()
}

@objc private protocol SwitchSMCtlDaemonProtocol {
  func getCapabilities(withReply reply: @escaping (Data?, String?) -> Void)
  func setFanManual(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
  func setFanAuto(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
  func setFanProfile(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

private struct SMCtlCapabilities: Decodable { let fanControlSupported: Bool }
private struct SMCtlEmpty: Decodable {}
private struct SMCtlManualRequest: Encodable { let index: Int; let rpm: Double; let force = false }
private struct SMCtlAutoRequest: Encodable { let index: Int? = nil }
private struct SMCtlProfileRequest: Encodable { let name: String }

private final class SMCtlResultBox {
  private let lock = NSLock()
  private var storedData: Data?
  private var storedError: String?

  func store(data: Data?, error: String?) {
    lock.lock()
    storedData = data
    storedError = error
    lock.unlock()
  }

  var result: (Data?, String?) {
    lock.lock()
    defer { lock.unlock() }
    return (storedData, storedError)
  }
}

private final class SMCtlClient {
  private let connection: NSXPCConnection

  init() {
    connection = NSXPCConnection(
      machServiceName: "one.leaper.smctl.daemon", options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: SwitchSMCtlDaemonProtocol.self)
    connection.resume()
  }

  deinit { connection.invalidate() }

  func capabilities() throws -> SMCtlCapabilities {
    try call { $0.getCapabilities(withReply: $1) }
  }

  func setManual(fan: Int, rpm: Double) throws {
    let request = try JSONEncoder().encode(SMCtlManualRequest(index: fan, rpm: rpm))
    let _: SMCtlEmpty = try call { $0.setFanManual(request, withReply: $1) }
  }

  func setAuto() throws {
    let request = try JSONEncoder().encode(SMCtlAutoRequest())
    let _: SMCtlEmpty = try call { $0.setFanAuto(request, withReply: $1) }
  }

  func setProfile(_ name: String) throws {
    let request = try JSONEncoder().encode(SMCtlProfileRequest(name: name))
    let _: SMCtlEmpty = try call { $0.setFanProfile(request, withReply: $1) }
  }

  private func call<Response: Decodable>(
    _ body: (SwitchSMCtlDaemonProtocol, @escaping (Data?, String?) -> Void) -> Void
  ) throws -> Response {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SMCtlResultBox()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      box.store(data: nil, error: error.localizedDescription)
      semaphore.signal()
    }) as? SwitchSMCtlDaemonProtocol else {
      throw FanControlError.helperUnavailable
    }
    body(proxy) { data, error in
      box.store(data: data, error: error)
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 1.5) == .success else {
      throw FanControlError.timedOut
    }
    let result = box.result
    if let error = result.1 { throw FanControlError.service(error) }
    guard let data = result.0 else { throw FanControlError.invalidResponse }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}
