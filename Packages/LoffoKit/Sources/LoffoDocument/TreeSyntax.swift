import Foundation
import LoffoDomain
import OSLog
import TreeSitter
import TreeSitterJava
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// One actor owns the parser and its editable tree. No C objects escape this boundary.
public actor TreeSyntax: SyntaxProviding {
    private struct ParseInput {
        let bytes: UnsafePointer<CChar>?
        let count: Int
        let deadline: UInt64
    }

    private struct PendingSpan {
        let startByte: Int
        let endByte: Int
        let kind: SyntaxKind
    }

    private let storage = ParserStorage()
    private var previous: TextSnapshot?
    var retainedSnapshot: TextSnapshot? { previous }
    private var languageExtension = ""
    private var cacheGeneration: UInt64 = 0
    private let admission: WorkAdmission
    fileprivate static let spanLimit = 120_000
    public init(admission: WorkAdmission = WorkAdmission()) { self.admission = admission }

    public func discardCachedTree() {
        cacheGeneration &+= 1
        discardTree()
    }

    #if DEBUG
        public var diagnosticHasCachedTree: Bool { previous != nil }
    #endif

    public func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan] {
        await highlightsWithStatus(for: snapshot).spans
    }

    public func highlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        await highlightsWithStatus(for: snapshot, retainingTree: true)
    }

    public func transientHighlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        await highlightsWithStatus(for: snapshot, retainingTree: false)
    }

    private func highlightsWithStatus(for snapshot: TextSnapshot, retainingTree: Bool) async
        -> SyntaxHighlights
    {
        let generation = cacheGeneration
        let cost = snapshot.byteCount * 12 + Self.spanLimit * 48
        do { try await admission.acquire(bytes: cost) } catch {
            if !retainingTree { discardTree() }
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        let spans = compute(snapshot, retainingTree: retainingTree && generation == cacheGeneration)
        await admission.release(bytes: cost)
        return spans
    }

    private func compute(_ snapshot: TextSnapshot, retainingTree: Bool) -> SyntaxHighlights {
        let signposter = OSSignposter(subsystem: "app.loffo", category: "Syntax")
        let interval = signposter.beginInterval("syntaxComputed")
        defer { signposter.endInterval("syntaxComputed", interval) }
        defer { if !retainingTree { discardTree() } }
        let ext = snapshot.url.pathExtension.lowercased()
        guard !Task.isCancelled else { return SyntaxHighlights(spans: [], isLimited: true) }
        if ext == "py" || ext == "pyi" { return Self.pythonSpans(in: snapshot.text) }
        guard let parser = storage.parser else { return SyntaxHighlights(spans: [], isLimited: true) }
        ts_parser_reset(parser)
        let language: OpaquePointer?
        switch ext {
        case "ts", "js", "mjs", "cjs": language = tree_sitter_typescript()
        case "tsx", "jsx": language = tree_sitter_tsx()
        case "swift": language = tree_sitter_swift()
        case "rs": language = tree_sitter_rust()
        case "java": language = tree_sitter_java()
        default: return SyntaxHighlights(spans: [], isLimited: false)
        }
        guard ts_parser_set_language(parser, language) else {
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        let bytes = Array(snapshot.text.utf8)
        if let previous, previous.url == snapshot.url, languageExtension == ext, let tree = storage.tree {
            var edit = Self.edit(from: Array(previous.text.utf8), to: bytes)
            ts_tree_edit(tree, &edit)
        } else {
            storage.clearTree()
        }
        let tree = bytes.withUnsafeBytes { raw in
            var input = ParseInput(
                bytes: raw.baseAddress?.assumingMemoryBound(to: CChar.self), count: bytes.count,
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            return withUnsafeMutablePointer(to: &input) { context in
                let source = TSInput(
                    payload: context,
                    read: { payload, offset, _, length in
                        guard let payload, let length else { return nil }
                        let input = payload.assumingMemoryBound(to: ParseInput.self).pointee
                        let index = Int(offset)
                        guard index < input.count, let bytes = input.bytes else {
                            length.pointee = 0
                            return nil
                        }
                        length.pointee = UInt32(input.count - index)
                        return bytes.advanced(by: index)
                    },
                    encoding: TSInputEncodingUTF8, decode: nil)
                let options = TSParseOptions(
                    payload: context,
                    progress_callback: { state in
                        guard let payload = state?.pointee.payload else { return true }
                        let deadline = payload.assumingMemoryBound(to: ParseInput.self).pointee.deadline
                        return Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline
                    })
                return ts_parser_parse_with_options(parser, storage.tree, source, options)
            }
        }
        storage.clearTree()
        guard let tree else {
            previous = nil
            ts_parser_reset(parser)
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        storage.tree = tree
        previous = snapshot
        languageExtension = ext
        guard let query = storage.query(for: ext, language: language) else {
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        let cursor = storage.queryCursor
        guard let cursor else { return SyntaxHighlights(spans: [], isLimited: true) }
        ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree))
        var pending: [PendingSpan] = []
        var match = TSQueryMatch()
        var captureIndex: UInt32 = 0
        var capturedCount = 0
        var isLimited = false
        while ts_query_cursor_next_capture(cursor, &match, &captureIndex) {
            guard !Task.isCancelled else { return SyntaxHighlights(spans: [], isLimited: true) }
            capturedCount += 1
            guard capturedCount <= Self.spanLimit else {
                isLimited = true
                break
            }
            guard let captures = match.captures else { return SyntaxHighlights(spans: [], isLimited: true) }
            let capture = captures[Int(captureIndex)]
            var captureNameLength: UInt32 = 0
            guard
                let captureName = ts_query_capture_name_for_id(
                    query, capture.index, &captureNameLength)
            else {
                continue
            }
            let nameBytes = UnsafeBufferPointer(
                start: UnsafeRawPointer(captureName).assumingMemoryBound(to: UInt8.self),
                count: Int(captureNameLength))
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard let kind = Self.kind(capture: name, node: capture.node, extension: ext) else {
                continue
            }
            let start = Int(ts_node_start_byte(capture.node))
            let end = Int(ts_node_end_byte(capture.node))
            if kind == .string, Self.isImportPath(capture.node) {
                pending.append(PendingSpan(startByte: start, endByte: end, kind: .importPath))
            } else if end <= bytes.count, start <= end {
                pending.append(PendingSpan(startByte: start, endByte: end, kind: kind))
            }
        }
        isLimited = isLimited || ts_query_cursor_did_exceed_match_limit(cursor)
        pending.sort {
            $0.startByte == $1.startByte ? $0.endByte > $1.endByte : $0.startByte < $1.startByte
        }
        var nonOverlapping: [PendingSpan] = []
        nonOverlapping.reserveCapacity(pending.count)
        for span in pending where nonOverlapping.last.map({ span.startByte >= $0.endByte }) ?? true {
            nonOverlapping.append(span)
        }
        guard let spans = Self.utf16Spans(in: snapshot.text, pending: nonOverlapping) else {
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        return SyntaxHighlights(spans: spans, isLimited: isLimited)
    }

    private func discardTree() {
        storage.clearTree()
        previous = nil
        languageExtension = ""
    }

    private static func kind(capture: String, node: TSNode, extension ext: String) -> SyntaxKind? {
        if capture == "identifier", ["ts", "tsx", "js", "jsx", "mjs", "cjs"].contains(ext) {
            if isParameterBinding(node) { return .parameter }
            let parent = ts_node_parent(node)
            guard !ts_node_is_null(parent) else { return nil }
            switch String(cString: ts_node_type(parent)) {
            case "call_expression"
            where ts_node_eq(
                node, ts_node_child_by_field_name(parent, "function", 8)):
                return .functionCall
            case "new_expression"
            where ts_node_eq(
                node, ts_node_child_by_field_name(parent, "constructor", 11)):
                return .constructor
            default:
                return nil
            }
        }
        if capture == "keyword" || capture.hasPrefix("keyword.") { return .keyword }
        if capture == "type" || capture.hasPrefix("type.") { return .type }
        if capture == "string" || capture.hasPrefix("string.") { return .string }
        if capture == "comment" || capture.hasPrefix("comment.") { return .comment }
        if capture == "number" || capture.hasPrefix("number.") { return .number }
        if capture == "function.call" || capture == "function.method" { return .functionCall }
        if capture == "constructor" { return .constructor }
        if capture == "variable.parameter" { return .parameter }
        return nil
    }

    /// Follow binding fields only; defaults, computed keys and local destructuring are expressions.
    private static func isParameterBinding(_ node: TSNode) -> Bool {
        var child = node
        while true {
            let parent = ts_node_parent(child)
            guard !ts_node_is_null(parent) else { return false }
            switch String(cString: ts_node_type(parent)) {
            case "required_parameter", "optional_parameter":
                return ts_node_eq(child, ts_node_child_by_field_name(parent, "pattern", 7))
                    || ts_node_eq(child, ts_node_child_by_field_name(parent, "name", 4))
            case "arrow_function":
                return ts_node_eq(child, ts_node_child_by_field_name(parent, "parameter", 9))
            case "pair_pattern":
                guard ts_node_eq(child, ts_node_child_by_field_name(parent, "value", 5)) else { return false }
            case "assignment_pattern", "object_assignment_pattern":
                guard ts_node_eq(child, ts_node_child_by_field_name(parent, "left", 4)) else { return false }
            case "array_pattern", "object_pattern", "rest_pattern":
                break
            default:
                return false
            }
            child = parent
        }
    }

    private static func isImportPath(_ node: TSNode) -> Bool {
        let parent = ts_node_parent(node)
        return !ts_node_is_null(parent) && String(cString: ts_node_type(parent)) == "import_statement"
    }

    static func pythonSpans(in text: String, isCancelled: () -> Bool = { Task.isCancelled })
        -> SyntaxHighlights
    {
        let pattern =
            ##"(?m)(#[^\n]*)|((?i:[rubf]{0,2})(?:'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|'(?:\\\\.|[^'\\\\])*'|\"(?:\\\\.|[^\"\\\\])*\"))|(\b\d+(?:\.\d+)?\b)|(\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b)"##
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return SyntaxHighlights(spans: [], isLimited: true)
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var spans: [SyntaxSpan] = []
        var limited = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) { match, _, stop in
            if isCancelled() {
                limited = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            guard spans.count < spanLimit else {
                limited = true
                stop.pointee = true
                return
            }
            let kind: SyntaxKind
            if match.range(at: 1).location != NSNotFound {
                kind = .comment
            } else if match.range(at: 2).location != NSNotFound {
                kind = .string
            } else if match.range(at: 3).location != NSNotFound {
                kind = .number
            } else {
                kind = .keyword
            }
            spans.append(SyntaxSpan(range: match.range, kind: kind))
        }
        return SyntaxHighlights(spans: spans, isLimited: limited)
    }

    /// Convert only the syntax ranges Tree-sitter emitted. A byte-sized offset table costs 4× the
    /// source size even for ASCII; walking scalar boundaries once keeps this temporary O(spans).
    private static func utf16Spans(in text: String, pending: [PendingSpan]) -> [SyntaxSpan]? {
        var scalars = text.unicodeScalars.makeIterator()
        var byteOffset = 0
        var utf16Offset = 0
        var scalarCount = 0
        var result: [SyntaxSpan] = []
        result.reserveCapacity(pending.count)
        for span in pending {
            guard span.startByte >= byteOffset, span.endByte >= span.startByte else { return nil }
            while byteOffset < span.startByte {
                guard let scalar = scalars.next() else { return nil }
                scalarCount += 1
                if scalarCount.isMultiple(of: 4_096), Task.isCancelled { return nil }
                byteOffset += scalar.utf8.count
                utf16Offset += scalar.utf16.count
            }
            let start = utf16Offset
            while byteOffset < span.endByte {
                guard let scalar = scalars.next() else { return nil }
                scalarCount += 1
                if scalarCount.isMultiple(of: 4_096), Task.isCancelled { return nil }
                byteOffset += scalar.utf8.count
                utf16Offset += scalar.utf16.count
            }
            guard byteOffset == span.endByte else { return nil }
            result.append(
                SyntaxSpan(range: NSRange(location: start, length: utf16Offset - start), kind: span.kind))
        }
        return result
    }

    private static func edit(from old: [UInt8], to new: [UInt8]) -> TSInputEdit {
        var prefix = 0
        var suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        // A tree edit must start/end on UTF-8 scalar boundaries, including emoji.
        while prefix > 0, prefix < old.count, old[prefix] & 0xC0 == 0x80 { prefix -= 1 }
        while suffix < min(old.count, new.count) - prefix,
            old[old.count - suffix - 1] == new[new.count - suffix - 1]
        { suffix += 1 }
        while suffix > 0, old[old.count - suffix] & 0xC0 == 0x80 { suffix -= 1 }
        func point(_ bytes: [UInt8], _ end: Int) -> TSPoint {
            var row: UInt32 = 0
            var column: UInt32 = 0
            for byte in bytes.prefix(end) {
                if byte == 10 {
                    row += 1
                    column = 0
                } else {
                    column += 1
                }
            }
            return TSPoint(row: row, column: column)
        }
        return TSInputEdit(
            start_byte: UInt32(prefix), old_end_byte: UInt32(old.count - suffix),
            new_end_byte: UInt32(new.count - suffix), start_point: point(old, prefix),
            old_end_point: point(old, old.count - suffix), new_end_point: point(new, new.count - suffix))
    }
}

private final class ParserStorage {
    let parser = ts_parser_new()
    let queryCursor = ts_query_cursor_new()
    var tree: OpaquePointer?
    private var queries: [String: OpaquePointer] = [:]

    init() {
        if let queryCursor { ts_query_cursor_set_match_limit(queryCursor, UInt32(TreeSyntax.spanLimit)) }
    }

    func query(for fileExtension: String, language: OpaquePointer?) -> OpaquePointer? {
        let queryName: String
        switch fileExtension {
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": queryName = "typescript"
        case "swift": queryName = "swift"
        case "rs": queryName = "rust"
        case "java": queryName = "java"
        default: return nil
        }
        if let cached = queries[queryName] { return cached }
        guard
            let language,
            let url = Bundle.module.url(forResource: queryName, withExtension: "scm"),
            let source = try? String(contentsOf: url, encoding: .utf8),
            source.utf8.count <= Int(UInt32.max)
        else { return nil }
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let query = source.withCString {
            ts_query_new(language, $0, UInt32(source.utf8.count), &errorOffset, &errorType)
        }
        if let query { queries[queryName] = query }
        return query
    }

    func clearTree() {
        if let tree { ts_tree_delete(tree) }
        tree = nil
    }
    deinit {
        clearTree()
        for query in queries.values { ts_query_delete(query) }
        if let queryCursor { ts_query_cursor_delete(queryCursor) }
        if let parser { ts_parser_delete(parser) }
    }
}
