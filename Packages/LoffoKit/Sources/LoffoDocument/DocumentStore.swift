import Foundation
import LoffoDomain
import OSLog

public actor DocumentStore {
    private let io: BoundedIO
    private var sequence: UInt64 = 0
    private struct Observation: Sendable {
        let snapshot: TextSnapshot
        let isMissing: Bool
    }
    private struct Read {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<Observation, any Error>]
    }
    private enum Key: Hashable, Sendable {
        case absolute(URL)
        case workspace(URL, String)

        var url: URL {
            switch self {
            case .absolute(let url): return url
            case .workspace(let root, let path): return root.appendingPathComponent(path)
            }
        }
    }
    private var cached: [Key: Observation] = [:]
    private var recency: [Key] = []
    private var cacheGeneration: UInt64 = 0
    private var inFlight: [Key: Read] = [:]
    var activeReadSubscribers: Int { inFlight.values.reduce(0) { $0 + $1.subscribers.count } }
    private let byteLimit = 2 * 1024 * 1024
    public init(io: BoundedIO) { self.io = io }

    public func discardCachedSnapshots() {
        cacheGeneration &+= 1
        cached.removeAll()
        recency.removeAll()
    }

    #if DEBUG
        public var diagnosticCachedBytes: Int { cached.values.reduce(0) { $0 + $1.snapshot.byteCount } }
    #endif

    public func read(_ url: URL) async throws -> TextSnapshot {
        let observation = try await observe(.absolute(url))
        guard !observation.isMissing else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return observation.snapshot
    }

    /// Only a comparison already identified as deleted may interpret a missing path as empty.
    public func readDeletedOrCurrent(_ url: URL) async throws -> TextSnapshot {
        try await observe(.absolute(url)).snapshot
    }

    public func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot {
        let observation = try await observe(.workspace(root, path))
        guard allowMissing || !observation.isMissing else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return observation.snapshot
    }

    private func observe(_ key: Key) async throws -> Observation {
        try Task.checkCancellation()
        let subscriber = UUID()
        let result: Observation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Observation, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if inFlight[key] != nil {
                    inFlight[key]?.subscribers[subscriber] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        do {
                            let observation = try await self.load(key)
                            self.finishRead(key: key, id: id, result: .success(observation))
                        } catch {
                            self.finishRead(key: key, id: id, result: .failure(error))
                        }
                    }
                    inFlight[key] = Read(id: id, task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelReadSubscriber(key: key, subscriber: subscriber) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancelReadSubscriber(key: Key, subscriber: UUID) {
        guard let continuation = inFlight[key]?.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(throwing: CancellationError())
        if inFlight[key]?.subscribers.isEmpty == true { inFlight.removeValue(forKey: key)?.task.cancel() }
    }

    private func finishRead(key: Key, id: UUID, result: Result<Observation, any Error>) {
        guard inFlight[key]?.id == id, let read = inFlight.removeValue(forKey: key) else { return }
        for subscriber in read.subscribers.values { subscriber.resume(with: result) }
    }

    private func load(_ key: Key) async throws -> Observation {
        let signposter = OSSignposter(subsystem: "app.loffo", category: "Document")
        let interval = signposter.beginInterval("snapshotRead")
        defer { signposter.endInterval("snapshotRead", interval) }
        let limit = byteLimit
        let generation = cacheGeneration
        let text: String? = try await io.run {
            do {
                let data: Data
                switch key {
                case .absolute(let url): data = try StableFileReader.read(url, limit: limit)
                case .workspace(let root, let path):
                    data = try StableFileReader.read(in: root, path: path, limit: limit)
                }
                return try TextLimits.decode(data)
            } catch {
                let failure = error as NSError
                if failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT) { return nil }
                throw error
            }
        }
        let missing = text == nil
        let content = text ?? ""
        if generation == cacheGeneration, let previous = cached[key], previous.isMissing == missing,
            previous.snapshot.text.utf8.elementsEqual(content.utf8)
        {
            recency.removeAll { $0 == key }
            recency.append(key)
            return previous
        }
        sequence += 1
        let observation = Observation(
            snapshot: TextSnapshot(url: key.url, version: sequence, text: content), isMissing: missing)
        guard generation == cacheGeneration else { return observation }
        cached[key] = observation
        recency.removeAll { $0 == key }
        recency.append(key)
        while cached.values.reduce(0, { $0 + $1.snapshot.byteCount }) > 8 * 1024 * 1024 || recency.count > 8 {
            cached.removeValue(forKey: recency.removeFirst())
        }
        return observation
    }
}
