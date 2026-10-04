import AppKit
import Core
import Integrations
import Viewers

/// Icon, name, and an optional note-count badge. Ignored files are dimmed.
final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let marker = NoteMarkerView()
    /// On a collapsed folder's icon: the open document is somewhere inside.
    private let activeDot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Follow the column as the sidebar resizes, so the note mark stays at the row's visible trailing edge.
        autoresizingMask = [.width]
        iconView.imageScaling = .scaleProportionallyDown
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        activeDot.wantsLayer = true
        activeDot.layer?.cornerRadius = 3.5
        activeDot.layer?.borderWidth = 1.5
        activeDot.alphaValue = 0
        activeDot.toolTip = "The open file is in this folder"
        for view in [iconView, nameField, marker, activeDot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 4),
            marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            activeDot.widthAnchor.constraint(equalToConstant: 7),
            activeDot.heightAnchor.constraint(equalToConstant: 7),
            activeDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            activeDot.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 1),
        ])
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        marker.setContentHuggingPriority(.required, for: .horizontal)
        marker.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = iconView
        textField = nameField
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with node: FileNode, mark: NoteMark? = nil, folderCount: Int = 0, holdsActive: Bool = false, animated: Bool = false) {
        // A pull request's root is its number on disk; it reads as the pull request.
        let isPullRoot = node.hostID == .github && node.parent == nil
        let isAtlassianRoot = node.hostID == .atlassian && node.parent == nil
        nameField.stringValue = isPullRoot ? (PullRequestPath(node.path).map { "\($0.repo) #\($0.number)" } ?? node.name)
            : isAtlassianRoot ? (SwitcherEntry.atlassianLabel(node.path) ?? node.name) : node.name
        let symbol = isPullRoot ? "arrow.triangle.pull" : isAtlassianRoot ? (node.path.hasPrefix("/jira") ? "ticket" : "doc.text")
            : (node.hostID == .atlassian && node.isDirectory ? "doc.text" : node.isDirectory ? "folder" : "doc")
        iconView.image = node.hostID == .local
            ? NSWorkspace.shared.icon(forFile: node.path)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let dim = node.isIgnored || node.entry.isHidden
        nameField.textColor = dim ? .tertiaryLabelColor : .labelColor
        iconView.alphaValue = dim ? 0.5 : 1
        marker.update(mark: mark, folderCount: folderCount, animated: animated)
        setHoldsActive(holdsActive, animated: animated)
        setAccessibilityLabel(Self.spokenLabel(name: node.name, isDirectory: node.isDirectory, mark: mark, folderCount: folderCount, holdsActive: holdsActive))
    }

    /// The row as VoiceOver reads it: the marker's count and colour and the open-file dot carry meaning too.
    nonisolated static func spokenLabel(name: String, isDirectory: Bool, mark: NoteMark?, folderCount: Int, holdsActive: Bool) -> String {
        var parts = [name]
        if let mark, mark.count > 0 {
            parts.append(mark.count == 1 ? "1 open note" : "\(mark.count) open notes")
            if mark.needsAttention { parts.append("needs attention") }
        } else if isDirectory, folderCount > 0 {
            parts.append(folderCount == 1 ? "1 open note inside" : "\(folderCount) open notes inside")
        }
        if holdsActive { parts.append("contains the open file") }
        return parts.joined(separator: ", ")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotColors()
    }

    /// Layer colours don't follow appearance changes on their own.
    private func updateDotColors() {
        // On a selected row the accent would vanish into the highlight: white, without the ring, instead.
        let emphasized = backgroundStyle == .emphasized
        effectiveAppearance.performAsCurrentDrawingAppearance {
            activeDot.layer?.backgroundColor = (emphasized ? NSColor.white : NSColor.controlAccentColor).cgColor
            activeDot.layer?.borderColor = emphasized ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.cgColor
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateDotColors() }
    }

    private func setHoldsActive(_ on: Bool, animated: Bool) {
        updateDotColors()
        let target: CGFloat = on ? 1 : 0
        guard activeDot.alphaValue != target else { return }
        if animated, !Motion.isReduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                activeDot.animator().alphaValue = target
            }
        } else {
            activeDot.alphaValue = target
        }
    }
}

/// A file row's open notes: overlapping dots in the notes' colours and the count, in a soft capsule (orange when
/// something needs attention). A folder shows only the quiet total of what is inside.
final class NoteMarkerView: NSView {
    /// Quiet but legible: tertiary reads on the light sidebar, but over dark vibrancy it nearly vanishes at 9 pt.
    static let folderCountColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private var mark: NoteMark?
    private var folderCount = 0
    private static let dot: CGFloat = 7
    private static let overlap: CGFloat = 3
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    override var isFlipped: Bool { true }

    func update(mark: NoteMark?, folderCount: Int, animated: Bool) {
        guard mark != self.mark || folderCount != self.folderCount else { return }
        let appearing = self.mark == nil && self.folderCount == 0
        self.mark = mark
        self.folderCount = folderCount
        invalidateIntrinsicContentSize()
        needsDisplay = true
        isHidden = mark == nil && folderCount == 0
        guard animated, !isHidden else { return }
        // A gentle pop so a change in the tree is noticed without demanding attention.
        wantsLayer = true
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = appearing ? 0.4 : 0.8
        pop.toValue = 1
        pop.damping = 12
        pop.duration = pop.settlingDuration
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.position = CGPoint(x: frame.midX, y: frame.midY)
        layer?.add(pop, forKey: "pop")
    }

    private var countText: String {
        if let mark { return "\(mark.count)" }
        return folderCount > 0 ? "\(folderCount)" : ""
    }

    override var intrinsicContentSize: NSSize {
        let text = (countText as NSString).size(withAttributes: [.font: Self.font]).width
        guard let mark else { return NSSize(width: folderCount > 0 ? ceil(text) + 2 : 0, height: 14) }
        let dots = CGFloat(mark.colors.count) * Self.dot - CGFloat(max(0, mark.colors.count - 1)) * Self.overlap
        return NSSize(width: ceil(5 + dots + 4 + text + 6), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any]
        guard let mark else {
            attributes = [.font: Self.font, .foregroundColor: Self.folderCountColor]
            (countText as NSString).draw(at: NSPoint(x: 1, y: 1), withAttributes: attributes)
            return
        }
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (mark.needsAttention ? NSColor.systemOrange.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
        capsule.fill()
        let y = (bounds.height - Self.dot) / 2
        let positions = mark.colors.indices.map { 5 + CGFloat($0) * (Self.dot - Self.overlap) }
        // Drawn back to front, so later dots tuck under earlier ones and the most used colour reads first.
        for (index, color) in mark.colors.enumerated().reversed() {
            let rect = NSRect(x: positions[index], y: y, width: Self.dot, height: Self.dot)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
            Theme.color(for: color).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        let x = (positions.last ?? 5) + Self.dot + 4
        attributes = [.font: Self.font, .foregroundColor: mark.needsAttention ? NSColor.systemOrange : NSColor.secondaryLabelColor]
        (countText as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: attributes)
    }
}
