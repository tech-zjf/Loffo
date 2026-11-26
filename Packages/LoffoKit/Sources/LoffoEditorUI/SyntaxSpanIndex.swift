import Foundation
import LoffoDomain

/// Index UTF-16 ranges by start and prefix maximum end, retaining original paint order.
struct SyntaxSpanIndex: Sendable {
    // Swift arrays share immutable storage with the presentation. The index stores only offsets,
    // so a window does not duplicate every span while preserving the original paint order.
    private let spans: [SyntaxSpan]
    private let entries: [Int]
    private let maximumEnds: [Int]

    init(_ spans: [SyntaxSpan]) {
        self.spans = spans
        entries = spans.indices.filter { index in
            let range = spans[index].range
            return range.location != NSNotFound && range.location >= 0 && range.length > 0
                && !range.location.addingReportingOverflow(range.length).overflow
        }.sorted {
            if spans[$0].range.location != spans[$1].range.location {
                return spans[$0].range.location < spans[$1].range.location
            }
            return $0 < $1
        }
        var maxima: [Int] = []
        maxima.reserveCapacity(entries.count)
        var maximum = 0
        for entry in entries {
            maximum = max(maximum, NSMaxRange(spans[entry].range))
            maxima.append(maximum)
        }
        maximumEnds = maxima
    }

    func intersecting(_ visible: NSRange, storageLength: Int) -> [SyntaxSpan] {
        guard visible.length > 0, visible.location != NSNotFound else { return [] }
        let visibleEnd = visible.location.addingReportingOverflow(visible.length)
        guard !visibleEnd.overflow else { return [] }
        var low = 0
        var high = maximumEnds.count
        while low < high {
            let middle = low + (high - low) / 2
            if maximumEnds[middle] <= visible.location { low = middle + 1 } else { high = middle }
        }
        var matches: [Int] = []
        while low < entries.count && spans[entries[low]].range.location < visibleEnd.partialValue {
            let index = entries[low]
            let end = NSMaxRange(spans[index].range)
            if end > visible.location && end <= storageLength { matches.append(index) }
            low += 1
        }
        return matches.sorted().map { spans[$0] }
    }
}
