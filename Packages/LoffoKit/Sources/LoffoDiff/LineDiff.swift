import Foundation
import LoffoDomain
import OSLog

/// A bounded LCS core for the spike. Prefix/suffix trimming keeps localized edits small.
/// Large rewrites produce a complete coarse diff instead of unbounded quadratic work.
public actor LineDiff: DiffComputing {
    private enum Step {
        case context(String)
        case added(String)
        case removed(String)
    }

    private let cellBudget: Int
    private let myersDistanceBudget: Int
    private let admission: WorkAdmission
    public init(
        cellBudget: Int = 400_000, myersDistanceBudget: Int = 256,
        admission: WorkAdmission = WorkAdmission()
    ) {
        self.cellBudget = max(1, cellBudget)
        self.myersDistanceBudget = max(0, myersDistanceBudget)
        self.admission = admission
    }

    public func compare(before: String, after: String) async throws -> DiffResult {
        let cost = (before.utf8.count + after.utf8.count) * 6 + cellBudget * 4
        try await admission.acquire(bytes: cost)
        let result = compute(before: before, after: after, forceCoarse: false)
        await admission.release(bytes: cost)
        try Task.checkCancellation()
        return result
    }

    private func compute(before: String, after: String, forceCoarse: Bool) -> DiffResult {
        let signposter = OSSignposter(subsystem: "app.loffo", category: "Diff")
        let interval = signposter.beginInterval("diffComputed")
        defer { signposter.endInterval("diffComputed", interval) }
        let old = Self.lines(before)
        let new = Self.lines(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix].utf8.elementsEqual(new[prefix].utf8) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
            old[old.count - suffix - 1].utf8.elementsEqual(new[new.count - suffix - 1].utf8)
        { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        var output: [DiffLine] = []
        var oldNumber = 1
        var newNumber = 1
        func append(_ text: String, _ kind: DiffKind) {
            output.append(
                DiffLine(
                    text: text, kind: kind,
                    oldNumber: kind == .added ? nil : oldNumber,
                    newNumber: kind == .removed ? nil : newNumber))
            if kind != .added { oldNumber += 1 }
            if kind != .removed { newNumber += 1 }
        }
        for line in old.prefix(prefix) { append(line, .context) }
        let cells = (a.count + 1).multipliedReportingOverflow(by: b.count + 1)
        let matrixFits = !cells.overflow && cells.partialValue <= cellBudget
        let myersSteps =
            !forceCoarse && !matrixFits && !Task.isCancelled
            ? Self.myers(a, b, maximumDistance: myersDistanceBudget)
            : nil
        let coarse = forceCoarse || Task.isCancelled || (!matrixFits && myersSteps == nil)
        if coarse {
            for line in a { append(line, .removed) }
            for line in b { append(line, .added) }
        } else if let myersSteps {
            for step in myersSteps {
                switch step {
                case .context(let line): append(line, .context)
                case .added(let line): append(line, .added)
                case .removed(let line): append(line, .removed)
                }
            }
        } else {
            let width = b.count + 1
            var lengths = [Int32](repeating: 0, count: cells.partialValue)
            if !a.isEmpty && !b.isEmpty {
                for i in stride(from: a.count - 1, through: 0, by: -1) {
                    for j in stride(from: b.count - 1, through: 0, by: -1) {
                        lengths[i * width + j] =
                            a[i].utf8.elementsEqual(b[j].utf8)
                            ? 1 + lengths[(i + 1) * width + j + 1]
                            : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < a.count || j < b.count {
                if i < a.count && j < b.count && a[i].utf8.elementsEqual(b[j].utf8) {
                    append(a[i], .context)
                    i += 1
                    j += 1
                } else if i < a.count
                    && (j == b.count || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1])
                {
                    append(a[i], .removed)
                    i += 1
                } else {
                    append(b[j], .added)
                    j += 1
                }
            }
        }
        for line in old.suffix(suffix) { append(line, .context) }
        return DiffResult(lines: output, isCoarse: coarse)
    }

    /// Myers finds small edit distances in large files without allocating an N×M matrix.
    /// The distance limit bounds both trace storage and worst-case comparison work.
    private static func myers(_ old: [String], _ new: [String], maximumDistance: Int) -> [Step]? {
        let maximum = min(maximumDistance, old.count + new.count)
        let offset = old.count + new.count + 1
        var frontier = [Int](repeating: -1, count: 2 * offset + 1)
        frontier[offset + 1] = 0
        var trace: [[Int]] = []
        trace.reserveCapacity(maximum + 1)
        var finalDistance: Int?

        for distance in 0...maximum {
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let index = offset + diagonal
                var x: Int
                if diagonal == -distance
                    || (diagonal != distance && frontier[index - 1] < frontier[index + 1])
                {
                    x = frontier[index + 1]
                } else {
                    x = frontier[index - 1] + 1
                }
                var y = x - diagonal
                while x < old.count, y < new.count,
                    old[x].utf8.elementsEqual(new[y].utf8)
                {
                    x += 1
                    y += 1
                }
                frontier[index] = x
                if x >= old.count, y >= new.count {
                    finalDistance = distance
                    break
                }
            }
            trace.append(Array(frontier[(offset - distance)...(offset + distance)]))
            if finalDistance != nil { break }
        }
        guard let finalDistance else { return nil }

        func value(in layer: [Int], distance: Int, diagonal: Int) -> Int {
            layer[diagonal + distance]
        }
        var x = old.count
        var y = new.count
        var reversed: [Step] = []
        if finalDistance > 0 {
            for distance in stride(from: finalDistance, through: 1, by: -1) {
                let previous = trace[distance - 1]
                let diagonal = x - y
                let previousDiagonal: Int
                if diagonal == -distance
                    || (diagonal != distance
                        && value(in: previous, distance: distance - 1, diagonal: diagonal - 1)
                            < value(in: previous, distance: distance - 1, diagonal: diagonal + 1))
                {
                    previousDiagonal = diagonal + 1
                } else {
                    previousDiagonal = diagonal - 1
                }
                let previousX = value(
                    in: previous, distance: distance - 1, diagonal: previousDiagonal)
                let previousY = previousX - previousDiagonal
                while x > previousX, y > previousY {
                    reversed.append(.context(old[x - 1]))
                    x -= 1
                    y -= 1
                }
                if x == previousX {
                    reversed.append(.added(new[y - 1]))
                    y -= 1
                } else {
                    reversed.append(.removed(old[x - 1]))
                    x -= 1
                }
            }
        }
        while x > 0, y > 0 {
            reversed.append(.context(old[x - 1]))
            x -= 1
            y -= 1
        }
        while x > 0 {
            reversed.append(.removed(old[x - 1]))
            x -= 1
        }
        while y > 0 {
            reversed.append(.added(new[y - 1]))
            y -= 1
        }
        return reversed.reversed()
    }

    /// Keep terminators so projecting either side reproduces the exact input.
    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            let end = text.index(after: index)
            result.append(String(text[start..<end]))
            start = end
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }
}
