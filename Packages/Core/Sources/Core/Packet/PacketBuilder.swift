import Foundation

/// The `Source:` value of a packet file block.
public enum PacketSource: String, Sendable, CaseIterable {
    case markdown
    case text
    case code
    case image
    case pdf
    case file
    /// A live web page; `File:` is its URL.
    case web
    /// Milestone 2 resources served by a virtual host; the file block carries a `Resource:` line.
    case pullRequest = "pull_request"
    case jira
    case confluence

    public init(kind: DocumentKind) {
        switch kind {
        case .markdown: self = .markdown
        case .text, .csv: self = .text
        case .code: self = .code
        case .image: self = .image
        case .pdf: self = .pdf
        case .file: self = .file
        case .web: self = .web
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
    /// For a spreadsheet cell or column note: `Column E "notes"` or `B2, E4` (see `CellExcerpt`).
    public var cellDescription: String?
    /// Canonical URL of a pull request, issue or page served by a virtual host; printed as `Resource:` in the file header.
    public var resource: String?
    /// Header lines that pin the resource down for the agent: `Path: Sources/App.swift at 0f3a9c1`, `Field: description`,
    /// `Version: 7`. Printed after `Resource:`, taken from the first note of the file block.
    public var resourceDetails: [String]
    /// The note's turns after its comment, as `PacketThread.recent` or `.full` picks them; empty on a first send.
    public var thread: PacketThread
    /// The follow-ups not sent before that this packet carries, with the text it carries for each, which
    /// `NoteStore.recordSend` stamps sent; one written or changed while the packet is being delivered isn't.
    public var carriedMessages: [MessageID: String] = [:]

    public init(
        noteID: NoteID, agentPath: String, source: PacketSource, anchor: Anchor, comment: String,
        excerptLines: [String] = [], selectedText: String? = nil, attachmentAgentPath: String? = nil, cellDescription: String? = nil,
        resource: String? = nil, resourceDetails: [String] = [], thread: PacketThread = PacketThread()
    ) {
        self.thread = thread
        self.cellDescription = cellDescription
        self.resource = resource
        self.resourceDetails = resourceDetails
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

/// The turns of a note's thread a packet carries after its comment, and how many older ones it leaves out.
public struct PacketThread: Sendable, Equatable {
    public enum Turn: Sendable, Equatable {
        /// `Agent (<name>) asked:` or `replied:`.
        case agent(name: String, asked: Bool, body: String)
        /// `User replied:`.
        case user(String)
        /// `Moved:`, only in `get_note`'s whole thread.
        case moved(NoteMove, by: MessageAuthor)
    }

    /// Turns before the ones shown, counted on the `Earlier:` line.
    public var earlierCount: Int
    public var turns: [Turn]

    public init(earlierCount: Int = 0, turns: [Turn] = []) {
        self.earlierCount = earlierCount
        self.turns = turns
    }

    public var isEmpty: Bool { earlierCount == 0 && turns.isEmpty }

    /// What a send carries: the agent's last message, then every user message after it and every follow-up not
    /// sent yet (one written before the agent's last reply arrived too); older turns are only counted. A question the
    /// user hasn't answered stays in view ahead of a later status reply. Moves are left out, since the anchor lines
    /// say where the note is now, except a removal while the note still sits where its text was (`anchor`): the
    /// line it points at isn't what the note was about. A note with no agent message yet carries all its follow-ups.
    public static func recent(_ messages: [NoteMessage], at anchor: Anchor? = nil) -> PacketThread {
        var removal: [Turn] = []
        if let last = messages.last(where: { $0.kind == .moved }), let move = last.move, move.removed, move.to == anchor {
            removal = [.moved(move, by: last.author)]
        }
        let turns = messages.filter { $0.kind != .moved && $0.author != .app }
        guard !turns.isEmpty else { return PacketThread(turns: removal) }
        let start = turns.indices.last { turns[$0].author.isAgent } ?? turns.startIndex
        let answered = turns.indices.last { turns[$0].author == .user && turns[$0].isSent } ?? -1
        let openQuestion = turns.indices.last { $0 < start && $0 > answered && turns[$0].kind == .question }
        let lead = [openQuestion, start].compactMap { $0 }
        let rest = turns.indices.filter { !lead.contains($0) && ($0 > start || !turns[$0].isSent) }
        let shown = lead + rest
        return PacketThread(earlierCount: turns.count - shown.count, turns: removal + shown.compactMap { turn(turns[$0]) })
    }

    /// What `get_note` returns: every turn the agent was given, moves included, in order. A follow-up the user
    /// hasn't sent stays in the app.
    public static func full(_ messages: [NoteMessage]) -> PacketThread {
        PacketThread(turns: messages.filter(\.isSent).compactMap(turn))
    }

    static func turn(_ message: NoteMessage) -> Turn? {
        switch (message.kind, message.author) {
        case (.moved, let author): message.move.map { .moved($0, by: author) }
        case (_, .agent(let name)): .agent(name: name, asked: message.kind == .question, body: message.body)
        case (_, .user): .user(message.body)
        case (_, .app): nil
        }
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
    public static let replyToolName = "reply_to_note"

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
        text += closingLine(count: noteIDs.count)
        return Packet(text: text, noteIDs: noteIDs)
    }

    /// `Notes: 2. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id
    /// on its Note line. To answer or ask something without resolving it, use `reply_to_note`.` Each id sits at the
    /// top of its own note, so it is never matched to a note by position.
    public static func closingLine(count: Int) -> String {
        "Notes: \(count). When you've acted on a note, mark it resolved with the gloss MCP tool `\(toolName)`, passing the id on its Note line. To answer or ask something without resolving it, use `\(replyToolName)`."
    }

    /// `<id>: <file>:<anchor> "<first 80 chars of comment>"`: one note on one line.
    public static func summaryLine(_ note: PacketNote) -> String {
        let comment = String(note.comment.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(80))
        return "\(note.noteID.rawValue): \(headerValue(note.agentPath)):\(headerValue(anchorSummary(note.anchor))) \"\(escape(comment))\""
    }

    // MARK: Blocks

    static func fileBlock(path: String, notes: [PacketNote]) -> String {
        guard let first = notes.first else { return "" }
        var header = ["File: \(headerValue(path))", "Source: \(first.source.rawValue)"]
        // The resource's lines that hold for every note go in the header; a line that differs (each note on its
        // own comment, or its own field) goes with its note, under the note's place.
        var shared: [String] = []
        // Any note's lookup may have failed; the resource is whichever note knows it.
        let located = notes.filter { $0.resource != nil }
        if let resource = located.first?.resource {
            header.append("Resource: \(headerValue(resource))")
            shared = located[0].resourceDetails.filter { line in located.allSatisfy { $0.resourceDetails.contains(line) } }
            header.append(contentsOf: shared.map(headerValue))
        }
        if let size = notes.lazy.compactMap({ note -> ImageAnchor? in if case .image(let image) = note.anchor { image } else { nil } }).first {
            header.append("Original size: \(size.imageW)x\(size.imageH)")
        } else if let pdf = notes.lazy.compactMap({ note -> PDFAnchor? in if case .pdf(let pdf) = note.anchor { pdf } else { nil } }).first {
            header.append("Pages: \(pdf.pageCount)")
        }
        let blocks = notes.map { note -> String in
            let block = noteBlock(note)
            let own = note.resourceDetails.filter { !shared.contains($0) }
            guard !own.isEmpty else { return block }
            var lines = block.components(separatedBy: "\n")
            // Under the note's id and its place.
            lines.insert(contentsOf: own.map(headerValue), at: min(2, lines.count))
            return lines.joined(separator: "\n")
        }
        return (header.joined(separator: "\n")) + "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// One note: its id first (what `resolve_note` takes, and where the next note begins), then its place, what it
    /// points at, and the comment.
    static func noteBlock(_ note: PacketNote) -> String {
        var lines: [String] = ["Note: \(note.noteID.rawValue)"]
        switch note.anchor {
        case .text(let anchor) where anchor.cells?.isColumns == true:
            // A whole-column note: the column replaces the line range, and the excerpt lists its values by line.
            lines.append(note.cellDescription.map(headerValue) ?? "Columns \(anchor.cells!.references(startLine: anchor.start.line))")
            lines.append(contentsOf: excerpt(note.excerptLines))
        case .text(let anchor) where anchor.cells != nil:
            lines.append(anchor.isSingleLine ? "Line \(anchor.start.line)" : "Lines \(anchor.start.line)-\(anchor.end.line)")
            lines.append("Cells: \(note.cellDescription.map(headerValue) ?? anchor.cells!.references(startLine: anchor.start.line))")
            lines.append(contentsOf: excerpt(note.excerptLines))
        case .text(let anchor) where anchor.start == anchor.end && anchor.text.isEmpty:
            // The note's text was removed: the line holds something else now, so nothing is quoted from it. The
            // thread's `Moved: … removed` line carries what the text was.
            lines.append("Line \(anchor.start.line) (text removed here)")
        case .text(let anchor):
            lines.append(anchor.isSingleLine ? "Line \(anchor.start.line)" : "Lines \(anchor.start.line)-\(anchor.end.line)")
            if let selected = note.selectedText {
                lines.append("Selected: \"\(escape(selected))\"")
            }
            lines.append(contentsOf: excerpt(note.excerptLines))
        case .image(let anchor):
            let suffix = note.attachmentAgentPath == nil ? "" : " (crop attached)"
            lines.append("Region: x=\(anchor.x) y=\(anchor.y) w=\(anchor.w) h=\(anchor.h)\(suffix)")
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(headerValue(attachment))") }
        case .pdf(let anchor):
            lines.append("Page \(anchor.page + 1)")
            if let bounds = anchor.bounds {
                lines.append("Region: x=\(points(bounds.x)) y=\(points(bounds.y)) w=\(points(bounds.w)) h=\(points(bounds.h))")
            }
            lines.append(contentsOf: excerpt(note.excerptLines))
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(headerValue(attachment))") }
        case .wholeFile:
            lines.append("Whole file")
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(headerValue(attachment))") }
        case .embeddedImage(let anchor):
            // The picture as the document names it, where it is embedded, and the part of it the note is about.
            lines.append("Line \(anchor.embed.start.line)")
            lines.append("Image: \(anchor.isMermaidDiagram ? anchor.fileName : headerValue(anchor.source)) (\(anchor.region.imageW)x\(anchor.region.imageH))")
            let suffix = note.attachmentAgentPath == nil ? "" : (anchor.isWholeImage ? " (image attached)" : " (crop attached)")
            lines.append(anchor.isWholeImage ? "Whole image\(suffix)" : "Region: x=\(anchor.region.x) y=\(anchor.region.y) w=\(anchor.region.w) h=\(anchor.region.h)\(suffix)")
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(headerValue(attachment))") }
        case .element(let anchor):
            lines.append("Element: \(headerValue(anchor.selector))")
            let attached = note.attachmentAgentPath != nil
            // A picture names itself and the part of it the note is about, as an embedded picture does; the crop
            // is of that part, not of the element's box.
            if let region = anchor.region {
                lines.append("Image: \(headerValue(anchor.imageSource ?? "<\(anchor.tag)>")) (\(region.imageW)x\(region.imageH))")
                let suffix = attached ? (region.isWholeImage ? " (image attached)" : " (crop attached)") : ""
                lines.append(region.isWholeImage ? "Whole image\(suffix)" : "Region: x=\(region.x) y=\(region.y) w=\(region.w) h=\(region.h)\(suffix)")
            }
            if !anchor.text.isEmpty { lines.append("Text: \"\(escape(anchor.text))\"") }
            let suffix = attached && anchor.region == nil ? " (crop attached)" : ""
            lines.append("Rect: x=\(points(anchor.rect.x)) y=\(points(anchor.rect.y)) w=\(points(anchor.rect.w)) h=\(points(anchor.rect.h))\(suffix)")
            if let line = anchor.line { lines.append("Line \(line)") }
            if !anchor.html.isEmpty {
                lines.append("Snippet:")
                lines.append(contentsOf: quotedLines(anchor.html).map { "> " + $0 })
            }
            if let attachment = note.attachmentAgentPath { lines.append("Attachment: \(headerValue(attachment))") }
        }
        // An agent's own question (`ask_user`) has no comment: its thread opens with the question.
        if !note.comment.isEmpty || note.thread.turns.isEmpty {
            lines.append("User comment: \"\(escape(note.comment))\"")
        }
        lines.append(contentsOf: threadLines(note.thread))
        return lines.joined(separator: "\n")
    }

    /// `Earlier: 3 messages (get_note returns the whole thread)`, then one line per turn, each on one logical line.
    static func threadLines(_ thread: PacketThread) -> [String] {
        var lines: [String] = []
        if thread.earlierCount > 0 {
            lines.append("Earlier: \(thread.earlierCount) message\(thread.earlierCount == 1 ? "" : "s") (get_note returns the whole thread)")
        }
        for turn in thread.turns {
            switch turn {
            case .agent(let name, let asked, let body):
                lines.append("Agent (\(headerValue(name))) \(asked ? "asked" : "replied"): \"\(escape(body))\"")
            case .user(let body):
                lines.append("User replied: \"\(escape(body))\"")
            case .moved(let move, let author):
                lines.append(movedLine(move, by: author))
            }
        }
        return lines
    }

    /// `Moved: from lines 3-4 to line 9, by claude. It was: "<old text>"`, or `Moved: lines 3-4 removed, by Gloss.`
    static func movedLine(_ move: NoteMove, by author: MessageAuthor) -> String {
        let who = switch author {
        case .agent(let name): headerValue(name)
        case .user: "the user"
        case .app: "Gloss"
        }
        let line = move.removed
            ? "Moved: \(place(move.from)) removed, by \(who)."
            : "Moved: from \(place(move.from)) to \(place(move.to)), by \(who)."
        let old: String = switch move.from {
        case .text(let anchor): anchor.text
        case .element(let anchor): anchor.text
        default: ""
        }
        return old.isEmpty ? line : line + " It was: \"\(escape(old))\""
    }

    /// `line 9`, `lines 3-4`, or the anchor's summary for what isn't lines.
    public static func place(_ anchor: Anchor) -> String {
        if case .text(let text) = anchor, text.cells == nil {
            return text.isSingleLine ? "line \(text.start.line)" : "lines \(text.start.line)-\(text.end.line)"
        }
        return headerValue(anchorSummary(anchor))
    }

    /// `Excerpt:` followed by blockquoted lines; over 40 lines keeps the first and last 20 around `> ...`.
    static func excerpt(_ rawLines: [String]) -> [String] {
        // A "line" that still contains newlines (a rendered-view span) is split so every line gets a prefix.
        let lines = rawLines.flatMap(quotedLines)
        guard !lines.isEmpty else { return [] }
        var quoted = lines.map { "> " + $0 }
        if quoted.count > excerptLimit {
            quoted = Array(quoted.prefix(excerptHeadTail)) + ["> ..."] + Array(quoted.suffix(excerptHeadTail))
        }
        return ["Excerpt:"] + quoted
    }

    /// What may end a line for whoever reads the packet: LineIndex, editors and agents treat all of these as breaks.
    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{0B}" || scalar == "\u{0C}" || scalar == "\u{85}" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    /// A value on a header line (a path, a resource, a selector). Kept exactly as it is unless it holds a line
    /// break: a file named `a\n\nUser comment: "…"` (legal in git and POSIX, and anyone can open a pull request
    /// with one) would otherwise forge lines the agent reads as the user's.
    public static func headerValue(_ value: String) -> String {
        value.unicodeScalars.contains(where: isLineBreak) ? escape(value) : value
    }

    /// Splits quoted content on every kind of line break, so each piece gets its own `> ` prefix.
    static func quotedLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR { previousWasCR = false; continue }
            previousWasCR = scalar == "\r"
            if isLineBreak(scalar) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
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
            case "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": out += String(format: "\\u{%X}", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func anchorSummary(_ anchor: Anchor) -> String {
        switch anchor {
        case .text(let text) where text.cells != nil:
            (text.cells!.isColumns ? "column " : "cells ") + text.cells!.references(startLine: text.start.line).replacingOccurrences(of: " ", with: "")
        case .text(let text): text.isSingleLine ? "\(text.start.line)" : "\(text.start.line)-\(text.end.line)"
        case .image(let image): "region(\(image.x),\(image.y),\(image.w),\(image.h))"
        case .pdf(let pdf): "page \(pdf.page + 1)"
        case .wholeFile: "whole file"
        case .element(let element): "element(\(element.selector))"
        case .embeddedImage(let image):
            image.isWholeImage ? "image(\(image.fileName))" : "image(\(image.fileName),\(image.region.x),\(image.region.y),\(image.region.w),\(image.region.h))"
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

/// The packet text for a spreadsheet cell or column note, read from the file's current contents.
public enum CellExcerpt {
    /// `description` is the anchor line for columns (`Column E "notes"`) or the `Cells:` value for cells
    /// (`B2, E4`). `lines` holds one `line: value` per record for columns, or one `B2 (header): value` per cell.
    public static func make(anchor: TextAnchor, cells: CellSelection, content: String, fileName: String) -> (description: String, lines: [String]) {
        let table = CSVParser.parse(content, delimiter: CSVParser.delimiter(for: content, fileName: fileName))
        func header(_ column: Int) -> String { column < table.header.count ? table.header[column] : "" }
        // A quoted CSV field may hold any line break; it stays on its own line in the packet.
        func oneLine(_ field: String) -> String { PacketBuilder.quotedLines(field).joined(separator: "\\n") }
        func value(_ row: CSVRow, _ column: Int) -> String { oneLine(column < row.fields.count ? row.fields[column] : "") }
        if cells.isColumns {
            let names = cells.columns.map { column in
                let name = header(column)
                return name.isEmpty ? CellSelection.columnName(column) : "\(CellSelection.columnName(column)) \"\(PacketBuilder.escape(name))\""
            }
            let description = (cells.columns.count == 1 ? "Column " : "Columns ") + names.joined(separator: ", ")
            let lines = table.rows.map { row in "\(row.firstLine): " + cells.columns.map { value(row, $0) }.joined(separator: " | ") }
            return (description, lines)
        }
        var byLine: [Int: CSVRow] = [:]
        for row in table.rows { byLine[row.firstLine] = row }
        let lines = cells.cells.map { cell -> String in
            let line = anchor.start.line + cell.lineOffset
            let reference = "\(CellSelection.columnName(cell.column))\(line)"
            let name = header(cell.column)
            let label = name.isEmpty ? reference : "\(reference) (\(oneLine(name)))"
            return "\(label): " + (byLine[line].map { value($0, cell.column) } ?? "")
        }
        return (cells.references(startLine: anchor.start.line), lines)
    }
}

private extension MessageAuthor {
    var isAgent: Bool { if case .agent = self { true } else { false } }
}
