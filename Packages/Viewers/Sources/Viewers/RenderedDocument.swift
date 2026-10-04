import AppKit
import Foundation

/// A document with a rendered view beside its source (markdown, HTML). Notes live in source coordinates; the
/// rendered view maps its selection back and shows source highlights.
public protocol RenderedDocumentController: AnyObject {
    var source: TextEditorController { get }
    var isShowingRendered: Bool { get }
    func toggle()
    /// A real (non-empty) selection in the rendered view.
    var hasRenderedSelection: Bool { get }
    /// The rendered selection in source coordinates.
    var renderedSelectionMapping: RenderedSourceMap.Mapping? { get }
    /// On-screen rectangle (top-left window coordinates) of a source range in whichever view is showing.
    func rect(forSource range: NSRange) -> CGRect?
    func scroll(toSource range: NSRange, select: Bool)
    func collapseRenderedSelection()
    /// Re-renders immediately when the source was replaced wholesale (reload, merge).
    func syncWithSourceIfReplaced()
}

extension MarkdownViewerController: RenderedDocumentController {
    public var isShowingRendered: Bool { mode == .rendered }
    public var hasRenderedSelection: Bool { renderedSelection.length > 0 }
}
