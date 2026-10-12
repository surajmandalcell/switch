import CoreServices
import Foundation

protocol ChatHistoryMonitoring: Sendable {
  func changes() -> AsyncStream<Void>
}

enum ChatHistoryEventPolicy {
  private static let recoveryFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagMustScanSubDirs
      | kFSEventStreamEventFlagUserDropped
      | kFSEventStreamEventFlagKernelDropped
      | kFSEventStreamEventFlagEventIdsWrapped
      | kFSEventStreamEventFlagRootChanged)

  static func shouldRefresh(homePath: String, path: String, flags: FSEventStreamEventFlags) -> Bool {
    if flags & recoveryFlags != 0 { return true }
    let home = URL(fileURLWithPath: homePath).standardizedFileURL.path
    let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
    for directory in ["sessions", "archived_sessions"] {
      let root = home + "/" + directory
      if candidate == root || candidate.hasPrefix(root + "/") { return true }
    }
    let name = URL(fileURLWithPath: candidate).lastPathComponent
    return URL(fileURLWithPath: candidate).deletingLastPathComponent().path == home
      && ["state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"].contains(name)
  }
}

struct FSEventChatHistoryMonitor: ChatHistoryMonitoring {
  let home: URL

  func changes() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let subscription = FSEventSubscription(home: home, continuation: continuation)
      continuation.onTermination = { _ in subscription.stop() }
      subscription.start()
    }
  }
}

private final class FSEventSubscription: @unchecked Sendable {
  private let homePath: String
  private let continuation: AsyncStream<Void>.Continuation
  private let queue = DispatchQueue(
    label: "com.switch.chat-history-events", qos: .utility)
  private var stream: FSEventStreamRef?
  private var stopped = false
  private lazy var debouncer = ChatHistoryDebouncer(queue: queue, quiet: .milliseconds(500)) { [weak self] in
    guard let self, !self.stopped else { return }
    self.continuation.yield()
  }

  init(home: URL, continuation: AsyncStream<Void>.Continuation) {
    homePath = home.standardizedFileURL.path
    self.continuation = continuation
  }

  func start() {
    queue.async { [self] in
      guard !stopped else { return }
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil)
      guard let created = FSEventStreamCreate(
        nil,
        { _, info, eventCount, eventPaths, eventFlags, _ in
          guard let info else { return }
          let subscription = Unmanaged<FSEventSubscription>
            .fromOpaque(info)
            .takeUnretainedValue()
          let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
          let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
          subscription.signal(paths: paths, flags: flags)
        },
        &context,
        [homePath] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot)
      ) else {
        continuation.finish()
        return
      }
      stream = created
      FSEventStreamSetDispatchQueue(created, queue)
      guard FSEventStreamStart(created) else {
        FSEventStreamInvalidate(created)
        FSEventStreamRelease(created)
        stream = nil
        continuation.finish()
        return
      }
    }
  }

  func stop() {
    queue.async { [self] in
      guard !stopped else { return }
      stopped = true
      debouncer.cancel()
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
      }
    }
  }

  private func signal(paths: [String], flags: [FSEventStreamEventFlags]) {
    guard zip(paths, flags).contains(where: {
      ChatHistoryEventPolicy.shouldRefresh(homePath: homePath, path: $0.0, flags: $0.1)
    }) else { return }
    debouncer.poke()
  }
}

/// Fires once after `quiet` has passed with no `poke`. Every call must come from `queue`.
/// The quiet window counts from the last event batch FSEvents delivers. FSEvents may deliver the
/// batches of one burst far apart on a busy machine (750 ms seen under disk load), so a burst can
/// give two fires there. That is a duplicate refresh, never a lost one.
final class ChatHistoryDebouncer: @unchecked Sendable {
  private let queue: DispatchQueue
  private let quiet: DispatchTimeInterval
  private let fire: @Sendable () -> Void
  private var pending: DispatchWorkItem?

  init(queue: DispatchQueue, quiet: DispatchTimeInterval, fire: @escaping @Sendable () -> Void) {
    self.queue = queue
    self.quiet = quiet
    self.fire = fire
  }

  func poke() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.fire()
    }
    pending = work
    queue.asyncAfter(deadline: .now() + quiet, execute: work)
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }
}
