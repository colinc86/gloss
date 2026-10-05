import Core
import CoreGraphics
import Foundation
import Observation
import Viewers

/// The notes panel following the page (link) and the curves from each note on the page to its card (paths).
///
/// The viewer reports where its notes are through `NoteGeometry`; the panel reports where its cards are. Following
/// is one way: the page leads, and the list keeps the note nearest the middle of the page centred, except while the
/// pointer is over the list so it never moves under the reader.
@MainActor @Observable
final class NoteLinkModel {
    var isLinked = false {
        didSet {
            guard isLinked != oldValue else { return }
            persist("notes.link", isLinked)
            focusNoteID = nil
            if isLinked { requestRefresh() } else { clearViewer() }
        }
    }
    /// Paths only draw while linked; this keeps the reader's choice while link is off.
    var showsPaths = true {
        didSet { if showsPaths != oldValue { persist("notes.paths", showsPaths) } }
    }
    var drawsPaths: Bool { isLinked && showsPaths }

    /// Each visible note's highlight on the page, one rect per line, in window coordinates.
    private(set) var viewerRects: [NoteID: [CGRect]] = [:]
    /// The visible part of the page.
    private(set) var viewerViewport: CGRect?
    /// Where each card on screen is, in window coordinates; reported by the cards while paths draw.
    private(set) var cardRects: [NoteID: CGRect] = [:]
    /// The notes list's frame.
    var panelViewport: CGRect?
    /// The card under the pointer: its path is drawn strong.
    var hoveredNoteID: NoteID?
    /// The pointer is over the list: following waits so the list doesn't move under it.
    var isPointerInPanel = false
    /// Notes the list shows (its filters and search applied); others are not followed or drawn.
    @ObservationIgnored var listedIDs: Set<NoteID> = [] {
        didSet { if isLinked, listedIDs != oldValue { requestRefresh() } }
    }

    /// The note the list should centre; `focusRequest` bumps each time it should scroll there.
    private(set) var focusNoteID: NoteID?
    private(set) var focusRequest = 0

    @ObservationIgnored private let noteStore: NoteStore
    @ObservationIgnored private weak var geometry: NoteGeometry?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var isRestoring = false

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            let link = try? await noteStore.setting("notes.link")
            let paths = try? await noteStore.setting("notes.paths")
            isRestoring = true
            if let link { isLinked = link == "1" }
            if let paths { showsPaths = paths == "1" }
            isRestoring = false
        }
    }

    /// The viewer now in front, or nil for one without note positions (Quick Look, a folder).
    func attach(_ geometry: NoteGeometry?) {
        guard geometry !== self.geometry else { return }
        self.geometry?.onChange = nil
        self.geometry = geometry
        geometry?.onChange = { [weak self] in self?.requestRefresh() }
        focusNoteID = nil
        if geometry == nil { clearViewer() } else { requestRefresh() }
    }

    func detach(_ geometry: NoteGeometry) {
        guard geometry === self.geometry else { return }
        attach(nil)
    }

    /// A card moved (the list scrolled, a card grew) or left the screen (nil). Kept even while paths are off: a card
    /// only reports when it moves, so turning paths on must find every card where it already is.
    func card(_ id: NoteID, movedTo frame: CGRect?) {
        if cardRects[id] != frame { cardRects[id] = frame }
    }

    /// Scrolling announces every step; read the page once per run-loop turn.
    func requestRefresh() {
        guard isLinked, !refreshPending else { return }
        refreshPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard isLinked, let geometry else { return clearViewer() }
        let viewport = geometry.viewport()
        let rects = geometry.visibleNoteRects().filter { listedIDs.contains($0.key) }
        if viewerViewport != viewport { viewerViewport = viewport }
        if viewerRects != rects { viewerRects = rects }
        guard !isPointerInPanel, let viewport, let focus = Self.focus(visible: rects, viewport: viewport), focus != focusNoteID else { return }
        focusNoteID = focus
        focusRequest += 1
    }

    private func clearViewer() {
        if !viewerRects.isEmpty { viewerRects = [:] }
        viewerViewport = nil
    }

    private func persist(_ key: String, _ value: Bool) {
        guard !isRestoring else { return }
        Task { try? await noteStore.setSetting(key, value ? "1" : "0") }
    }

    /// The visible note nearest the middle of the page: one the middle runs through first, then the closest edge,
    /// then whichever comes first on the page.
    nonisolated static func focus(visible: [NoteID: [CGRect]], viewport: CGRect) -> NoteID? {
        let middle = viewport.midY
        func distance(_ rects: [CGRect]) -> CGFloat {
            let top = rects.map(\.minY).min() ?? .infinity, bottom = rects.map(\.maxY).max() ?? .infinity
            return middle >= top && middle <= bottom ? 0 : min(abs(top - middle), abs(bottom - middle))
        }
        return visible.filter { !$0.value.isEmpty }.min { a, b in
            let da = distance(a.value), db = distance(b.value)
            if da != db { return da < db }
            let ta = a.value.map(\.minY).min() ?? 0, tb = b.value.map(\.minY).min() ?? 0
            return ta != tb ? ta < tb : a.key.rawValue < b.key.rawValue
        }?.key
    }
}
