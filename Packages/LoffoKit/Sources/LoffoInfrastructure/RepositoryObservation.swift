import CoreServices
import Foundation

/// One recursive stream per subscribed root. Coalesced/dropped events trigger a complete metadata recheck.
@MainActor final class RepositoryObservation {
    var listeners: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var stream: FSEventStreamRef?

    init(root: URL) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        stream = FSEventStreamCreate(
            nil,
            { _, context, _, _, _, _ in
                guard let context else { return }
                // The stream is explicitly delivered on DispatchQueue.main below.
                MainActor.assumeIsolated {
                    let owner = Unmanaged<RepositoryObservation>.fromOpaque(context).takeUnretainedValue()
                    for listener in owner.listeners.values { listener() }
                }
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stop() }
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
}
