import Foundation
import LoffoDomain

struct QuickOpenIndex: Sendable {
    static let resultLimit = 200

    private struct Candidate: Sendable {
        let file: ProjectFile
        let path: [Character]
    }

    private struct RankedMatch: Sendable {
        let file: ProjectFile
        let score: Int
    }

    private let candidates: [Candidate]

    init(files: [ProjectFile]) {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 64), Self.currentTaskIsCancelled { break }
            candidates.append(Candidate(file: file, path: Array(file.path.lowercased())))
        }
        self.candidates = candidates
    }

    func matching(_ query: String) -> [ProjectFile] {
        search(query).files
    }

    func search(_ query: String) -> QuickOpenSearchResults {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return QuickOpenSearchResults(files: [], hasMore: false) }

        // Keep only the best visible rows plus one sentinel to tell the user to refine the query.
        // This bounds sorting, SwiftUI identity work, and scroll layout for broad searches.
        let capacity = Self.resultLimit + 1
        var best: [RankedMatch] = []
        best.reserveCapacity(capacity)
        for (candidateIndex, candidate) in candidates.enumerated() {
            if candidateIndex.isMultiple(of: 64), Self.currentTaskIsCancelled {
                return QuickOpenSearchResults(files: [], hasMore: false)
            }
            var queryIndex = 0
            var previousMatch = -2
            var score = 0
            for (index, character) in candidate.path.enumerated() where queryIndex < needle.count {
                guard character == needle[queryIndex] else { continue }
                let isSegmentStart = index == 0 || "/._- ".contains(candidate.path[index - 1])
                score += isSegmentStart ? 12 : 1
                if index == previousMatch + 1 { score += 8 }
                score -= index / 24
                previousMatch = index
                queryIndex += 1
            }
            guard queryIndex == needle.count else { continue }
            score -= candidate.path.count / 64
            let match = RankedMatch(file: candidate.file, score: score)
            if best.count < capacity {
                best.append(match)
                siftUp(&best, from: best.count - 1)
            } else if outranks(match, best[0]) {
                best[0] = match
                siftDown(&best, from: 0)
            }
        }
        guard !Self.currentTaskIsCancelled else {
            return QuickOpenSearchResults(files: [], hasMore: false)
        }
        best.sort(by: outranks)
        let hasMore = best.count > Self.resultLimit
        return QuickOpenSearchResults(
            files: best.prefix(Self.resultLimit).map(\.file), hasMore: hasMore)
    }

    private func siftUp(_ heap: inout [RankedMatch], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private func siftDown(_ heap: inout [RankedMatch], from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var worst = parent
            if left < heap.count, isWorse(heap[left], than: heap[worst]) { worst = left }
            if right < heap.count, isWorse(heap[right], than: heap[worst]) { worst = right }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }

    private func outranks(_ lhs: RankedMatch, _ rhs: RankedMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.file.path.localizedStandardCompare(rhs.file.path) == .orderedAscending
    }

    private func isWorse(_ lhs: RankedMatch, than rhs: RankedMatch) -> Bool {
        outranks(rhs, lhs)
    }

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }
}

struct QuickOpenSearchResults: Sendable {
    let files: [ProjectFile]
    let hasMore: Bool
}
