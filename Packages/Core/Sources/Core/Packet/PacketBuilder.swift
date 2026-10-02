import Foundation

/// The `Source:` value of a packet file block.
public enum PacketSource: String, Sendable, CaseIterable {
    case markdown
    case text
    case code
    case image
    case pdf
    case file

    public init(kind: DocumentKind) {
        switch kind {
        case .markdown: self = .markdown
        case .text, .csv: self = .text
        case .code: self = .code
        case .image: self = .image
        case .pdf: self = .pdf
        case .file: self = .file
        }
    }
}

/// One note, already resolved to paths on the agent's machine. The builder does no I/O.
public struct PacketNote: Sendable {
    public var noteID: NoteID
    /// Absolute path of the file on the machine where the agent runs.
    public var agentPath: String
    public var source: PacketSource
    public var anchor: Anchor
    public var comment: String
    /// The selected lines for text anchors, or the selected text lines for a PDF text selection.
    public var excerptLines: [String]
    /// Exact text of a rendered-markdown selection that spans part of one line.
    public var selectedText: String?
    /// Absolute path of the crop or page render on the agent's machine.
    public var attachmentAgentPath: String?

    public init(
        noteID: NoteID, agentPath: String, source: PacketSource, anchor: Anchor, comment: String,
        excerptLines: [String] = [], selectedText: String? = nil, attachmentAgentPath: String? = nil
    ) {
        self.noteID = noteID
        self.agentPath = agentPath
        self.source = source
        self.anchor = anchor
        self.comment = comment
        self.excerptLines = excerptLines
        self.selectedText = selectedText
        self.attachmentAgentPath = attachmentAgentPath
    }
}

public struct Packet: Sendable, Equatable {
    public var text: String
    public var noteIDs: [NoteID]

    public init(text: String, noteIDs: [NoteID]) {
        self.text = text
        self.noteIDs = noteIDs
    }
}

/// Builds the plain-text message agents receive. The grammar is fixed by the `context-packet` skill;
/// every transport emits exactly this text.
public enum PacketBuilder {
    public static let excerptLimit = 40
    public static let excerptHeadTail = 20
    public static let toolName = "resolve_note"

    public static func build(_ notes: [PacketNote]) -> Packet {
        var order: [String] = []
        var groups: [String: [PacketNote]] = [:]
        for note in notes {
            if groups[note.agentPath] == nil { order.append(note.agentPath) }
            groups[note.agentPath, default: []].append(note)
        }

        var fileBlocks: [String] = []
        var noteIDs: [NoteID] = []
        for path in order {
            let group = groups[path]!.sorted { lhs, rhs in
                if lhs.anchor.sortKey != rhs.anchor.sortKey { return lhs.anchor.sortKey < rhs.anchor.sortKey }
                return lhs.noteID.rawValue < rhs.noteID.rawValue
            }
            noteIDs.append(contentsOf: group.map(\.noteID))
            fileBlocks.append(fileBlock(path: path, notes: group))
        }

        var text = fileBlocks.joined(separator: "\n\n\n")
        if !text.isEmpty { text += "\n\n" }
        text += closingLine(noteIDs: noteIDs)
        return Packet(text: text, noteIDs: noteIDs)
    }

    /// `Notes: 2. Mark each resolved with the gloss MCP tool `resolve_note` (ids: a, b) when done.`
    public static func closingLine(noteIDs: [NoteID], maxIDs: Int? = nil) -> String {
        var ids = noteIDs.map(\.rawValue).joined(separator: ", ")
        if let maxIDs, noteIDs.count > maxIDs {
            ids = noteIDs.prefix(maxIDs).map(\.rawValue).joined(separator: ", ") + ", and \(noteIDs.count - maxIDs) more via `list_pending_notes`"
        }
        return "Notes: \(noteIDs.count). Mark each resolved with the gloss MCP tool `\(toolName)` (ids: \(ids)) when done."
    }

    /// Ids listed in a hook closing line before it falls back to "and N more".
    public static let hookClosingIDLimit = 40
    /// Claude Code and Codex cap `additionalContext` here.
    public static let hookDefaultLimit = 10_000

    /// `<id>: <file>:<anchor> "<first 80 chars of comment>"`, the hook form used when the full packet exceeds the cap.
    public static func summaryLine(_ note: PacketNote) -> String {
        let comment = String(note.comment.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(80))
        return "\(note.noteID.rawValue): \(note.agentPath):\(anchorSummary(note.anchor)) \"\(escape(comment))\""
    }

    /// The text for a `UserPromptSubmit` hook: the full packet when it fits in `limit` characters,
    /// otherwise one summary line per note plus the instruction to fetch full notes through MCP.
    public static func hookText(_ notes: [PacketNote], limit: Int = 10_000) -> String {
        // Nothing pending: the hook must add no context at all, not an empty packet with a closing line.
        if notes.isEmpty { return "" }
        let full = build(notes)
        if full.text.count <= limit { return full.text }
        var lines = [
            "\(notes.count) pending notes from Gloss (too large to inline). Call the gloss MCP tool `get_note` with an id for the full excerpt.",
        ]
        lines.append(contentsOf: notes.map(summaryLine))
        lines.append("")
        let closing = closingLine(noteIDs: notes.map(\.noteID), maxIDs: hookClosingIDLimit)
        lines.append(closing)
        var text = lines.joined(separator: "\n")
        if text.count > limit {
            // Keep as many whole summary lines as fit, then the closing line.
            var kept: [String] = [lines[0]]
            for line in notes.map(summaryLine) {
                let candidate = (kept + [line, "", closing]).joined(separator: "\n")
                if candidate.count > limit { break }
                kept.append(line)
            }
            text = (kept + ["", closing]).joined(separator: "\n")
        }
        return text
    }

    // MARK: Blocks

    static func fileBlock(path: String, notes: [PacketNote]) -> String {
        guard let first = notes.first else { return "" }
        var header = ["File: \(path)", "Source: \(first.source.rawValue)"]
        if let size = notes.lazy.compactMap({ note -> ImageAnchor? in if case .image(let image) = note.anchor { image } else { nil } }).first {
            header.append("Original size: \(size.imageW)x\(size.imageH)")
        } else if let pdf = notes.lazy.compactMap({ note -> PDFAnchor? in if case .pdf(let pdf) = note.anchor { pdf } else { nil } }).first {
            header.append("Pages: \(pdf.pageCount)")
        }
        let blocks = notes.map(noteBlock)
        return (header.joined(separator: "\n")) + "\n\n" + blocks.joined(separator: "\n\n")
    }

    static func noteBlock(_ note: PacketNote) -> String {
        var lines: [String] = []
        switch note.anchor {
        case .text(let anchor):
            lines.append(anchor.isSingleLine ? "Line \(anchor.start.line)" : "Lines \(anchor.start.line)-\(anchor.end.line)")
            if let selected = note.selectedText {
                lines.append("Selected: \"\(escape(selected))\"")
            }
            lines.append(contentsOf: excerpt(note.excerptLines))
        case .image(let anchor):
            let suffix = note.attachmentAgentPath == nil ? "" : " (crop attached)"
            lines.append("Region: x=\(anchor.x) y=\(anchor.y) w=\(anchor.w) h=\(anchor.h)\(suffix)")
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(attachment)") }
        case .pdf(let anchor):
            lines.append("Page \(anchor.page + 1)")
            if let bounds = anchor.bounds {
                lines.append("Region: x=\(points(bounds.x)) y=\(points(bounds.y)) w=\(points(bounds.w)) h=\(points(bounds.h))")
            }
            lines.append(contentsOf: excerpt(note.excerptLines))
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(attachment)") }
        case .wholeFile:
            lines.append("Whole file")
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(attachment)") }
        }
        lines.append("User comment: \"\(escape(note.comment))\"")
        return lines.joined(separator: "\n")
    }

    /// `Excerpt:` followed by blockquoted lines; over 40 lines keeps the first and last 20 around `> ...`.
    static func excerpt(_ rawLines: [String]) -> [String] {
        // A "line" that still contains newlines (a rendered-view span) is split so every line gets a prefix.
        let lines = rawLines.flatMap { $0.components(separatedBy: "\n") }.map { $0.replacingOccurrences(of: "\r", with: "") }
        guard !lines.isEmpty else { return [] }
        var quoted = lines.map { "> " + $0 }
        if quoted.count > excerptLimit {
            quoted = Array(quoted.prefix(excerptHeadTail)) + ["> ..."] + Array(quoted.suffix(excerptHeadTail))
        }
        return ["Excerpt:"] + quoted
    }

    /// Orca's rule: the comment stays on one logical line.
    public static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func anchorSummary(_ anchor: Anchor) -> String {
        switch anchor {
        case .text(let text): text.isSingleLine ? "\(text.start.line)" : "\(text.start.line)-\(text.end.line)"
        case .image(let image): "region(\(image.x),\(image.y),\(image.w),\(image.h))"
        case .pdf(let pdf): "page \(pdf.page + 1)"
        case .wholeFile: "whole file"
        }
    }

    static func points(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

/// Pulls the lines a text anchor covers out of a document's content, using the same line rules as `LineIndex`.
public enum ExcerptExtractor {
    /// Lines `anchor.start.line ... anchor.end.line` (1-based, inclusive), without their terminators.
    public static func lines(for anchor: TextAnchor, in content: String, index: LineIndex? = nil) -> [String] {
        let index = index ?? LineIndex(content)
        guard !content.isEmpty else { return [] }
        let start = max(1, anchor.start.line)
        var end = max(start, anchor.end.line)
        // A selection ending at column 1 of the next line does not include that line.
        if anchor.end.line > anchor.start.line && anchor.end.col <= 1 { end -= 1 }
        end = min(end, lastRealLine(index))
        guard start <= end else { return [] }
        return (start...end).compactMap { content.line($0, index: index) }
    }

    /// Every line of `content` without terminators; a trailing terminator does not add an empty last line.
    public static func allLines(_ content: String) -> [String] {
        let index = LineIndex(content)
        return (1...lastRealLine(index)).compactMap { content.line($0, index: index) }
    }

    /// The last line that holds content: a trailing terminator starts an empty line that is not a real line.
    static func lastRealLine(_ index: LineIndex) -> Int {
        guard index.lineCount > 1, index.contentRange(ofLine: index.lineCount).length == 0 else { return index.lineCount }
        return index.lineCount - 1
    }
}
