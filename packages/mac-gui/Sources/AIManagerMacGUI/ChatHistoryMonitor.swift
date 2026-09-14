import CoreServices
import Foundation

protocol ChatHistoryMonitoring: Sendable {
  func changes() -> AsyncStream<Void>
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
        { _, info, _, _, _, _ in
          guard let info else { return }
          Unmanaged<FSEventSubscription>
            .fromOpaque(info)
            .takeUnretainedValue()
            .signal()
        },
        &context,
        [homePath] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
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
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
      }
    }
  }

  private func signal() {
    continuation.yield()
  }
}
