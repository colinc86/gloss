import AppKit
import Core
import Foundation
import Observation

/// A note drawn on the image canvas, in original pixel coordinates.
public struct ImageHighlight: Identifiable, Equatable, Sendable {
    public var id: NoteID
    public var rect: CGRect
    public var color: NoteColor
    public var state: NoteState
    public var needsReview: Bool

    public init(id: NoteID, rect: CGRect, color: NoteColor, state: NoteState, needsReview: Bool = false) {
        self.id = id
        self.rect = rect
        self.color = color
        self.state = state
        self.needsReview = needsReview
    }
}

@Observable
public final class ImageViewerController {
    public enum ZoomCommand: Equatable {
        case fit
        case actualSize
        case zoomIn
        case zoomOut
    }

    public let image: DecodedImage
    /// Rectangle being drawn or just drawn, in pixel space; nil when nothing is selected.
    public var selection: CGRect?
    public var highlights: [ImageHighlight] = []
    public var selectedNoteID: NoteID?
    public var pendingZoom: ZoomCommand?
    public var pendingZoomVersion = 0
    @ObservationIgnored public var onNoteClick: (NoteID) -> Void = { _ in }
    /// Set by the view: converts a pixel rect to the scroll view's coordinates for popovers.
    @ObservationIgnored public var rectProvider: (CGRect) -> CGRect? = { _ in nil }

    public init(image: DecodedImage) {
        self.image = image
    }

    public func zoom(_ command: ZoomCommand) {
        pendingZoom = command
        pendingZoomVersion += 1
    }

    public func rect(forPixelRect rect: CGRect) -> CGRect? {
        rectProvider(rect)
    }

    public var selectionAnchor: ImageAnchor? {
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        let rect = selection.integral
        return ImageAnchor(x: Int(rect.minX), y: Int(rect.minY), w: Int(rect.width), h: Int(rect.height), imageW: image.width, imageH: image.height, hash: image.hash)
    }
}
