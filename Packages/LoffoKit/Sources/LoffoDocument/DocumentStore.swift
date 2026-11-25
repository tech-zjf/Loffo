import Foundation
import LoffoDomain
import OSLog

public actor DocumentStore {
    private let io: BoundedIO
    private var sequence: UInt64 = 0
    private var cached: [URL: TextSnapshot] = [:]
    private var recency: [URL] = []
    private var inFlight: [URL: Task<TextSnapshot, Error>] = [:]
    private let byteLimit = 2 * 1024 * 1024
    public init(io: BoundedIO) { self.io = io }

    public func read(_ url: URL) async throws -> TextSnapshot {
        if let task = inFlight[url] { return try await task.value }
        let task = Task { try await self.load(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    private func load(_ url: URL) async throws -> TextSnapshot {
        let signposter = OSSignposter(subsystem: "app.loffo", category: "Document")
        let interval = signposter.beginInterval("snapshotRead")
        defer { signposter.endInterval("snapshotRead", interval) }
        let limit = byteLimit
        let text = try await io.run {
            let data = try StableFileReader.read(url, limit: limit)
            let text = try TextLimits.decode(data)
            return text
        }
        if let snapshot = cached[url], snapshot.text.utf8.elementsEqual(text.utf8) { return snapshot }
        sequence += 1
        let snapshot = TextSnapshot(url: url, version: sequence, text: text)
        cached[url] = snapshot
        recency.removeAll { $0 == url }
        recency.append(url)
        while cached.values.reduce(0, { $0 + $1.byteCount }) > 8 * 1024 * 1024 || recency.count > 8 {
            cached.removeValue(forKey: recency.removeFirst())
        }
        return snapshot
    }
}
