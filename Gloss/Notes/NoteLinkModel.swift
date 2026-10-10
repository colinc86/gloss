import AppKit
import Core
import CoreGraphics
import Foundation
import Observation
import Viewers

/// The notes panel following the page (link) and the paths from each note on the page to its card.
///
/// The viewer reports where its notes are through `NoteGeometry`; the panel reports where its cards are. Following
/// is one way: the page leads, and the list keeps the note nearest the middle of the page centred, except while the
/// pointer is over the list so it never moves under the reader. Paths are drawn by `NotePathLayerView`, updated
/// here synchronously from the page's scroll notifications so they move in the same frame as the text.
@MainActor @Observable
final class NoteLinkModel {
    var isLinked = false {
        didSet {
            guard isLinked != oldValue else { return }
            persist("notes.link", isLinked)
            focusNoteID = nil
            if isLinked { refresh() } else { clearViewer() }
            updateShown()
        }
    }
    /// Paths only draw while linked; this keeps the reader's choice while link is off.
    var showsPaths = true {
        didSet {
            guard showsPaths != oldValue else { return }
            persist("notes.paths", showsPaths)
            redraw()
            updateShown()
        }
    }
    var drawsPaths: Bool { isLinked && showsPaths }
    /// The notes panel is on screen; paths have nothing to arrive at without it.
    @ObservationIgnored var isPanelShown = true {
        didSet {
            guard isPanelShown != oldValue else { return }
            // The page may have scrolled while the panel was away: draw where things are now before fading in.
            redraw()
            updateShown()
            drawSelections()
            layerView.setSelectionsShown(isPanelShown)
        }
    }

    /// The notes list's frame.
    @ObservationIgnored var panelViewport: CGRect? {
        didSet {
            guard panelViewport != oldValue else { return }
            // The whole list moved (the window resized, the header grew): every card moved with it, though no row did.
            NotificationCenter.default.post(name: Self.panelMoved, object: self)
            redraw()
            drawSelections()
        }
    }
    /// The toasts at the bottom of the list (Undo, a send's result), when any shows: cards under them are covered,
    /// so their ribbons stop as they would at the list's edge.
    @ObservationIgnored var panelToasts: CGRect? {
        didSet {
            guard panelToasts != oldValue else { return }
            redraw()
            drawSelections()
        }
    }
    /// The part of the list cards can be seen in.
    private var visibleList: CGRect? {
        guard var list = panelViewport else { return nil }
        if let toasts = panelToasts, toasts.minY > list.minY, toasts.minY < list.maxY { list.size.height = toasts.minY - list.minY }
        return list
    }
    /// The card under the pointer, the selected card and the note under the pointer on the page: their paths are
    /// drawn strong.
    @ObservationIgnored var hoveredNoteID: NoteID? { didSet { if hoveredNoteID != oldValue { redraw() } } }
    @ObservationIgnored var selectedNoteID: NoteID? { didSet { if selectedNoteID != oldValue { redraw() } } }
    @ObservationIgnored var peekedNoteID: NoteID? { didSet { if peekedNoteID != oldValue { redraw() } } }
    /// The pointer is over the list: following waits so the list doesn't move under it.
    @ObservationIgnored var isPointerInPanel = false
    /// Notes the list shows (its filters and search applied); others are not followed or drawn.
    @ObservationIgnored var listedIDs: Set<NoteID> = [] {
        didSet { if isLinked, listedIDs != oldValue { refresh() } }
    }
    /// A selected card, with its note's color, for the outline around adjacent selected cards.
    struct SelectedCard: Equatable {
        var id: NoteID
        var color: NoteColor
    }
    /// The runs of two or more adjacent selected cards, top to bottom in list order: one outline goes around each
    /// (issue #19), drawn whether or not paths are.
    @ObservationIgnored var selectionRuns: [[SelectedCard]] = [] {
        didSet {
            guard selectionRuns != oldValue else { return }
            selectedCardIDs = Set(selectionRuns.joined().map(\.id))
            drawSelections()
        }
    }
    @ObservationIgnored private var selectedCardIDs: Set<NoteID> = []
    /// The list has the keyboard in the key window: selection outlines are at full strength, half otherwise.
    @ObservationIgnored var listActive = true {
        didSet { if listActive != oldValue { drawSelections() } }
    }
    /// Each note's colour and how strongly its state shows (`Theme.strength`), for the active document.
    @ObservationIgnored var noteStyles: () -> [NoteID: (color: NoteColor, strength: CGFloat)] = { [:] }

    /// The note the list should centre; `focusRequest` bumps each time it should scroll there.
    private(set) var focusNoteID: NoteID?
    private(set) var focusRequest = 0

    /// Each visible note's highlight on the page, one rect per line, and the visible part of the page.
    @ObservationIgnored private(set) var viewerRects: [NoteID: [CGRect]] = [:]
    @ObservationIgnored private(set) var viewerViewport: CGRect?
    /// Where each card on screen is, in window coordinates.
    @ObservationIgnored private(set) var cardRects: [NoteID: CGRect] = [:]
    /// Which card view last placed each note's card: only it can take the card away, so a row leaving late (the
    /// note moved to the other run of a separated list) doesn't clear where its new row put it.
    @ObservationIgnored private var cardOwners: [NoteID: ObjectIdentifier] = [:]
    /// Posted when the notes list moves as a whole; card probes report where they are now.
    static let panelMoved = Notification.Name("NoteLinkModel.panelMoved")

    @ObservationIgnored private let noteStore: NoteStore
    @ObservationIgnored private weak var geometry: NoteGeometry?
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var settlePending = false
    /// What was drawn last, so a card moving redraws only its own ribbon.
    @ObservationIgnored private var drawn: [NoteID: NotePathLayerView.Item] = [:]
    @ObservationIgnored private let layerView = NotePathLayerView(frame: .zero)
    /// Outlines are rebuilt only when a note's rects change, not on every redraw.
    @ObservationIgnored private var outlines: [NoteID: (rects: [CGRect], shapes: [NoteOutline.Shape], path: CGPath)] = [:]

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
        layerView.onAppearanceChange = { [weak self] in
            self?.redraw()
            self?.drawSelections()
        }
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

    /// The window the paths are drawn in.
    func install(in window: NSWindow) {
        layerView.install(in: window)
        updateShown()
        redraw()
        drawSelections()
    }

    /// The viewer now in front, or nil for one without note positions (Quick Look, a folder).
    func attach(_ geometry: NoteGeometry?) {
        guard geometry !== self.geometry else { return }
        self.geometry?.onChange = nil
        self.geometry = geometry
        geometry?.onChange = { [weak self] in self?.pageMoved() }
        focusNoteID = nil
        if geometry == nil { clearViewer() } else { refresh() }
    }

    func detach(_ geometry: NoteGeometry) {
        guard geometry === self.geometry else { return }
        attach(nil)
    }

    /// A card moved (the list scrolled, a card grew) or left the screen (nil). Kept even while paths are off: a card
    /// only reports when it moves, so turning paths on must find every card where it already is.
    func card(_ id: NoteID, movedTo frame: CGRect?, owner: ObjectIdentifier? = nil) {
        if let owner {
            if frame == nil {
                guard cardOwners[id] == owner else { return }
                cardOwners[id] = nil
            } else {
                cardOwners[id] = owner
            }
        }
        guard cardRects[id] != frame else { return }
        cardRects[id] = frame
        if selectedCardIDs.contains(id) { drawSelections() }
        // Every card on screen reports on every frame of a list scroll: move just this one's ribbon.
        guard drawsPaths, isPanelShown, var item = drawn[id] else { return }
        item.card = frame
        drawn[id] = item
        layerView.updateRibbon(item, viewerViewport: viewerViewport, panelViewport: visibleList)
    }

    /// The page scrolled or laid out again. Read it now, so the outlines move in the same frame as the text, and once
    /// more after the pass: inside a scroll notification text layout hasn't caught up yet (a jump past what was laid
    /// out finds no notes until it has), and the last step of a scroll would otherwise leave new notes undrawn.
    private func pageMoved() {
        refresh()
        guard !settlePending else { return }
        settlePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.settlePending = false
                self?.refresh()
            }
        }
    }

    /// Reads the page and redraws.
    func refresh() {
        guard isLinked, let geometry else { return clearViewer() }
        let viewport = geometry.viewport()
        let rects = geometry.visibleNoteRects().filter { listedIDs.contains($0.key) }
        viewerViewport = viewport
        viewerRects = rects
        redraw()
        // The list follows the page as it scrolls, not while the window is being resized: the note in view changes
        // with every step then, and the list animated after it (#20).
        guard NSApp?.keyWindow?.inLiveResize != true else { return }
        guard !isPointerInPanel, let viewport, let focus = Self.focus(visible: rects, viewport: viewport), focus != focusNoteID else { return }
        focusNoteID = focus
        focusRequest += 1
    }

    private func clearViewer() {
        viewerRects = [:]
        viewerViewport = nil
        redraw()
    }

    private func updateShown() {
        layerView.setShown(drawsPaths && isPanelShown)
    }

    private func redraw() {
        guard drawsPaths, isPanelShown else { return }
        let styles = noteStyles()
        let strong = Set([hoveredNoteID, selectedNoteID, peekedNoteID].compactMap { $0 })
        var items: [NotePathLayerView.Item] = []
        for (id, rects) in viewerRects {
            guard let style = styles[id] else { continue }
            let outline: (rects: [CGRect], shapes: [NoteOutline.Shape], path: CGPath)
            if let cached = outlines[id], cached.rects == rects {
                outline = cached
            } else {
                let shapes = NoteOutline.shapes(rects)
                outline = (rects, shapes, NoteOutline.path(shapes))
                outlines[id] = outline
            }
            items.append(NotePathLayerView.Item(id: id, shapes: outline.shapes, outline: outline.path, card: cardRects[id],
                                                color: Theme.color(for: style.color), strength: style.strength, strong: strong.contains(id)))
        }
        outlines = outlines.filter { viewerRects[$0.key] != nil }
        drawn = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        layerView.update(items, viewerViewport: viewerViewport, panelViewport: visibleList)
    }

    /// Outlines each run of adjacent selected cards where its cards are now.
    private func drawSelections() {
        // Hidden with the panel, the outlines stay as they were while they fade.
        guard isPanelShown else { return }
        guard let list = visibleList else { return layerView.updateSelections([], list: nil, active: listActive) }
        let runs = selectionRuns.compactMap { run -> NotePathLayerView.Selection? in
            guard let rect = SelectionOutline.rect(run.map { cardRects[$0.id] }, list: list) else { return nil }
            let cards = run.compactMap { card in cardRects[card.id].map { (midY: $0.midY, color: card.color) } }
            let stops = SelectionOutline.stops(cards, in: rect).map { (location: $0.location, color: Theme.color(for: $0.color)) }
            return NotePathLayerView.Selection(rect: rect, stops: stops)
        }
        layerView.updateSelections(runs, list: list, active: listActive)
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
