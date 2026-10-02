import AppKit
import Core

/// Icon, name, and an optional note-count badge. Ignored files are dimmed.
final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        for view in [iconView, nameField, badge] {
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
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        imageView = iconView
        textField = nameField
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with node: FileNode) {
        nameField.stringValue = node.name
        iconView.image = node.hostID == .local
            ? NSWorkspace.shared.icon(forFile: node.path)
            : NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
        let dim = node.isIgnored || node.entry.isHidden
        nameField.textColor = dim ? .tertiaryLabelColor : .labelColor
        iconView.alphaValue = dim ? 0.5 : 1
        badge.stringValue = node.noteCount > 0 ? "\(node.noteCount)" : ""
        badge.isHidden = node.noteCount == 0
    }
}
