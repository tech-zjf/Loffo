import CoreServices
import Foundation
import LoffoDomain

/// Owns a recursive FSEvents stream for one repository root.
@MainActor final class RepositoryObservation {
    typealias StreamSetup = @Sendable (URL, RepositoryObservation) -> StartedStream

    var listeners: [UUID: @MainActor @Sendable (WorkspaceChange) -> Void] = [:]
    private let root: URL
    private let streamSetup: StreamSetup
    private var stream: FSEventStreamRef?
    private var startTask: Task<Void, Never>?
    private var startToken = UUID()
    private var rootChanged = false
    private var stopped = false

    var isActive: Bool { stream != nil && !rootChanged }

    init(root: URL) {
        self.root = root
        streamSetup = Self.createStream
    }

    init(root: URL, streamSetup: @escaping StreamSetup) {
        self.root = root
        self.streamSetup = streamSetup
    }

    func startIfNeeded() async {
        guard !isActive else { return }
        if let startTask {
            await startTask.value
            return
        }

        if stream != nil { stop() }
        stopped = false
        rootChanged = false
        let token = UUID()
        startToken = token
        let root = root
        let task = Task.detached(priority: .utility) { [self] in
            let result = streamSetup(root, self)
            await finishStarting(result, token: token)
        }
        startTask = task
        await task.value
    }

    private func finishStarting(_ result: StartedStream, token: UUID) {
        guard token == startToken, !stopped else {
            result.stop()
            return
        }
        guard result.started, let stream = result.stream else {
            startTask = nil
            result.stop()
            return
        }
        self.stream = stream
        startTask = nil
    }

    private func received(paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        if (0..<count).contains(where: {
            flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }) {
            rootChanged = true
        }
        let batch = Self.classify(paths: paths, flags: flags, count: count)
        for listener in listeners.values { listener(batch) }
    }

    func stop() {
        stopped = true
        startToken = UUID()
        startTask?.cancel()
        startTask = nil
        rootChanged = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private static nonisolated func createStream(
        root: URL, owner: RepositoryObservation
    ) -> StartedStream {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return StartedStream(stream: nil, started: false) }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<RepositoryObservation>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<RepositoryObservation>.fromOpaque(info).release()
            },
            copyDescription: nil)
        // Replay changes between choosing the cursor and registering the stream; the caller scans
        // immediately after installation, and replayed events invalidate any snapshot they race.
        let sinceWhen = FSEventsGetCurrentEventId()
        guard
            let stream = FSEventStreamCreate(
                nil,
                { _, context, count, eventPaths, flags, _ in
                    guard let context else { return }
                    let payload = EventCallbackPayload(
                        context: context, count: count, eventPaths: eventPaths, flags: flags)
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<RepositoryObservation>.fromOpaque(payload.context)
                            .takeUnretainedValue()
                        let paths =
                            Unmanaged<CFArray>.fromOpaque(payload.eventPaths)
                            .takeUnretainedValue() as NSArray
                        owner.received(paths: paths, flags: payload.flags, count: payload.count)
                    }
                }, &context, [root.path] as CFArray, sinceWhen, 0.25,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagUseCFTypes))
        else { return StartedStream(stream: nil, started: false) }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        return StartedStream(stream: stream, started: FSEventStreamStart(stream))
    }

    static func classify(
        paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>, count: Int
    ) -> WorkspaceChange {
        guard count > 0, count <= 512, paths.count == count else { return .rescan }
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let allowed = modified | file
        var urls: [URL] = []
        for index in 0..<count {
            let value = flags[index]
            guard value & modified != 0, value & file != 0, value & ~allowed == 0,
                let path = paths[index] as? String, path.hasPrefix("/")
            else { return .rescan }
            urls.append(URL(fileURLWithPath: path).standardizedFileURL)
        }
        return .fileContents(urls)
    }
}

/// FSEvents invokes this callback synchronously on the configured main queue. The raw pointers are
/// borrowed only until the callback returns and are consumed inside `MainActor.assumeIsolated`.
private struct EventCallbackPayload: @unchecked Sendable {
    let context: UnsafeMutableRawPointer
    let count: Int
    let eventPaths: UnsafeMutableRawPointer
    let flags: UnsafePointer<FSEventStreamEventFlags>
}

/// The opaque FSEvent reference moves once from the setup task to the main actor. All stream cleanup
/// and callbacks are serialized through the main queue after that handoff.
final class StartedStream: @unchecked Sendable {
    let stream: FSEventStreamRef?
    let started: Bool

    init(stream: FSEventStreamRef?, started: Bool) {
        self.stream = stream
        self.started = started
    }

    @MainActor func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
