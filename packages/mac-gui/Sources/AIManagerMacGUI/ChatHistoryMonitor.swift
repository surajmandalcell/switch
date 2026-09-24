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
  private var pendingSignal: DispatchWorkItem?

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
      pendingSignal?.cancel()
      pendingSignal = nil
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
    pendingSignal?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped else { return }
      self.pendingSignal = nil
      self.continuation.yield()
    }
    pendingSignal = work
    queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
  }
}
