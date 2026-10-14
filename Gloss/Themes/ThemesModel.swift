import AppKit
import Core
import Darwin
import Observation
import Viewers

nonisolated enum ThemeSlot: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "Light Appearance" : "Dark Appearance" }
    var appearance: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    var themeAppearance: CodeTheme.Appearance { self == .light ? .light : .dark }
}

@MainActor @Observable
final class ThemeDraft: Identifiable {
    nonisolated enum Kind { case edit, duplicate, imported }
    let id = UUID()
    let kind: Kind
    let slot: ThemeSlot
    let baseline: CodeTheme?
    var theme: CodeTheme { didSet { changed() } }
    var externalChanged = false
    var invalidFields: Set<String> = []
    var error: String?
    var report: ImportReport?
    @ObservationIgnored var changed: () -> Void = {}
    init(theme: CodeTheme, kind: Kind, slot: ThemeSlot, baseline: CodeTheme? = nil, report: ImportReport? = nil) {
        self.theme = theme; self.kind = kind; self.slot = slot; self.baseline = baseline; self.report = report
    }
    func setTokenStyle(_ style: TokenStyle,forKey key: String) {
        theme.setStyle(style,forKey: key,clearingDescendants: true)
    }
    var title: String {
        switch kind { case .edit: "Edit Theme"; case .duplicate: "Duplicate Theme"; case .imported: "Import Theme" }
    }
}

/// Settings choices and provisional editing. The store owns files; a sheet never writes until Save or Add Theme.
@MainActor @Observable
final class ThemesModel {
    let store: CodeThemeStore
    let settings: SettingsStore
    var draft: ThemeDraft?
    var error: String?
    var isImporting = false
    @ObservationIgnored var saveFile: (CodeTheme) throws -> Void
    @ObservationIgnored var deleteFile: (String) throws -> Void
    @ObservationIgnored private var stopped = false

    init(settings: SettingsStore, store: CodeThemeStore) {
        self.settings = settings; self.store = store
        saveFile = { try store.save($0) }; deleteFile = { try store.delete(id: $0) }
        settings.onCodeThemeChange = { [weak self] in self?.apply() }
        apply()
        watchStore()

    }
    func selectedID(_ slot: ThemeSlot) -> String { slot == .light ? settings.codeThemeLight : settings.codeThemeDark }
    func selected(_ slot: ThemeSlot) -> CodeTheme { store.resolve(id: selectedID(slot)).theme }
    func offered(_ slot: ThemeSlot) -> [CodeTheme] {
        store.themes.filter { $0.appearance == .any || $0.appearance == slot.themeAppearance || $0.id == selectedID(slot) }
    }
    func select(_ theme: CodeTheme, for slot: ThemeSlot) {
        if slot == .light { settings.codeThemeLightName = theme.name; settings.codeThemeLight = theme.id }
        else { settings.codeThemeDarkName = theme.name; settings.codeThemeDark = theme.id }
        apply()
    }
    func notice(_ slot: ThemeSlot) -> String? {
        guard store.resolve(id: selectedID(slot)).problem != nil else { return nil }
        let name = slot == .light ? settings.codeThemeLightName : settings.codeThemeDarkName
        return "\(name ?? selectedID(slot)) isn't available. Using Gloss."
    }
    func preview(_ slot: ThemeSlot) -> CodeTheme {
        if let draft, draft.kind == .edit, selectedID(slot) == draft.theme.id { return draft.theme }
        return selected(slot)
    }
    func apply() {
        guard !stopped else { return }
        if let draft, let baseline = draft.baseline, store.theme(id: baseline.id) != baseline { draft.externalChanged = true }
        ActiveCodeTheme.set(light: preview(.light),dark: preview(.dark))
    }
    private func watchStore() {
        guard !stopped else { return }
        withObservationTracking {
            _ = store.themes; _ = store.problems
        } onChange: { [weak self] in
            Task { @MainActor in self?.apply(); self?.watchStore() }
        }
    }
    func edit(_ slot: ThemeSlot) {
        let theme = selected(slot)
        guard !theme.isBuiltIn else { return }
        begin(ThemeDraft(theme: theme,kind: .edit,slot: slot,baseline: theme))
    }
    func duplicate(_ slot: ThemeSlot) {
        var theme = selected(slot)
        theme.name = uniqueName(theme.name + " Copy")
        theme.id = freshID(); theme.appearance = slot.themeAppearance
        begin(ThemeDraft(theme: theme,kind: .duplicate,slot: slot))
    }
    private func begin(_ draft: ThemeDraft) {
        guard self.draft == nil else { return }
        draft.changed = { [weak self] in self?.apply() }
        self.draft = draft
        apply()
    }
    func cancel() { draft = nil; store.reload(); apply() }

    /// A conflict keeps the draft intact until the user chooses Replace File or Save a Copy.
    @discardableResult
    func save(replacing: Bool = false, asCopy: Bool = false) -> Bool {
        guard let draft else { return false }
        // Check the file now, rather than trusting the debounced watcher's cached version.
        store.reload()
        if let baseline = draft.baseline, store.theme(id: baseline.id) != baseline { draft.externalChanged = true }
        guard !draft.externalChanged || replacing || asCopy else { return false }
        guard draft.invalidFields.isEmpty else { draft.error = "Check the color or font values before saving."; return false }
        var theme = draft.theme
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.name.isEmpty else { draft.error = "Give this theme a name."; return false }
        if asCopy { theme.id = freshID(); theme.name = uniqueName(theme.name + " Copy") }
        do {
            try saveFile(theme)
            self.draft = nil
            let slot = draft.kind == .imported ? (theme.appearance == .dark ? ThemeSlot.dark : .light) : draft.slot
            select(theme,for: slot)
            return true
        } catch { draft.error = "Couldn't save this theme. \(error.userMessage)"; return false }
    }
    func delete(_ slot: ThemeSlot) {
        let theme = selected(slot)
        guard !theme.isBuiltIn else { return }
        do {
            try deleteFile(theme.id)
            if settings.codeThemeLight == theme.id { select(.gloss,for: .light) }
            if settings.codeThemeDark == theme.id { select(.gloss,for: .dark) }
        } catch { self.error = "Couldn't delete this theme. \(error.userMessage)" }
    }
    func importFile(_ url: URL) async {
        guard !isImporting, draft == nil else { return }
        isImporting = true; error = nil
        defer { isImporting = false }
        do {
            let result = try await Task.detached {
                let descriptor = Darwin.open(url.path,O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw CodeThemeError.malformed("The theme file couldn't be opened.") }
                defer { Darwin.close(descriptor) }
                var info = stat()
                guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CodeThemeError.malformed("Choose a regular theme file.") }
                guard info.st_size <= CodeTheme.maximumFileSize else { throw CodeThemeError.tooLarge(bytes: Int(info.st_size)) }
                let file = FileHandle(fileDescriptor: descriptor,closeOnDealloc: false)
                let bytes = try file.read(upToCount: CodeTheme.maximumFileSize + 1) ?? Data()
                guard bytes.count <= CodeTheme.maximumFileSize else { throw CodeThemeError.tooLarge(bytes: bytes.count) }
                return try CodeThemeImporter.parse(bytes,fileName: url.lastPathComponent)
            }.value
            var theme = result.theme
            theme.id = freshID(); theme.name = uniqueName(theme.name)
            let slot: ThemeSlot = theme.appearance == .dark ? .dark : .light
            theme.appearance = slot.themeAppearance
            begin(ThemeDraft(theme: theme,kind: .imported,slot: slot,report: result.report))
        } catch { self.error = "Couldn't import this theme. \(error.userMessage)" }
    }
    func export(_ slot: ThemeSlot, to url: URL) {
        do { try store.export(selected(slot),to: url) }
        catch { self.error = "Couldn't export this theme. \(error.userMessage)" }
    }
    private func freshID() -> String { "user-" + UUID().uuidString.lowercased() }
    private func uniqueName(_ name: String) -> String {
        let names = Set(store.themes.map(\.name))
        if !names.contains(name) { return name }
        var number = 2
        while names.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }
    func stop() { stopped = true }
}
