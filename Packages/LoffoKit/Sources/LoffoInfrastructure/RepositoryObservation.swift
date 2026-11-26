import CoreServices
import Foundation
import LoffoDomain

/// One recursive stream per subscribed root. Coalesced/dropped events trigger a complete metadata recheck.
@MainActor final class RepositoryObservation {
    var listeners: [UUID: @MainActor @Sendable (WorkspaceChange) -> Void] = [:]
    private var stream: FSEventStreamRef?
    private var rootChanged = false
    var isActive: Bool { stream != nil && !rootChanged }

    init(root: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        stream = FSEventStreamCreate(
            nil,
            { _, context, count, eventPaths, flags, _ in
                guard let context else { return }
                // The stream is explicitly delivered on DispatchQueue.main below.
                MainActor.assumeIsolated {
                    let owner = Unmanaged<RepositoryObservation>.fromOpaque(context).takeUnretainedValue()
                    if (0..<count).contains(where: {
                        flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    }) {
                        owner.rootChanged = true
                    }
                    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                    let batch = RepositoryObservation.classify(paths: paths, flags: flags, count: count)
                    for listener in owner.listeners.values { listener(batch) }
                }
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stop() }
        }
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

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
}
