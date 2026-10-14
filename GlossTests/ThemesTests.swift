import AppKit
import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor @Suite(.serialized)
struct ThemesTests {
    func fixture() async throws -> (ThemesModel,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossThemeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let settings = SettingsStore(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        await settings.load()
        return (ThemesModel(settings: settings,store: CodeThemeStore(folder: folder.appendingPathComponent("Themes"),watches: false)),folder)
    }
    func theme(_ id: String = "fixture-light",appearance: CodeTheme.Appearance = .light) -> CodeTheme {
        var theme = CodeTheme.gloss
        theme.id = id; theme.name = "Example Palette"; theme.appearance = appearance
        theme.editor = .derived(background: ThemeColor("#FDFDFD")!,foreground: ThemeColor("#202020")!)
        return theme
    }
    func close(_ model: ThemesModel,_ folder: URL) {
        model.stop(); ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        try? FileManager.default.removeItem(at: folder)
    }
    @Test func appearanceSelectsIndependentThemeIds() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let light = theme(), dark = theme("fixture-dark",appearance: .dark)
        try model.store.save(light); try model.store.save(dark)
        model.select(light,for: .light)
        #expect(model.settings.codeThemeDark == "gloss")
        model.select(dark,for: .dark)
        #expect(ActiveCodeTheme.theme(for: NSAppearance(named: .aqua)!).id == light.id)
        #expect(ActiveCodeTheme.theme(for: NSAppearance(named: .darkAqua)!).id == dark.id)
        #expect(model.settings.codeThemeLight == light.id && model.settings.codeThemeDark == dark.id)
    }
    @Test func builtInsCannotBeEditedOrDeleted() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        var deleted = false; model.deleteFile = { _ in deleted = true }
        model.edit(.light); model.delete(.light)
        #expect(model.draft == nil && !deleted && model.selected(.light).id == "gloss")
    }
    @Test func duplicateCancelDoesNotSaveOrSelect() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let count = model.store.themes.count
        model.duplicate(.light)
        let draft = try #require(model.draft)
        #expect(draft.theme.id.hasPrefix("user-") && !draft.theme.isBuiltIn)
        #expect(model.store.theme(id: draft.theme.id) == nil && model.settings.codeThemeLight == "gloss")
        draft.theme.editor.background = ThemeColor("#223344")!
        model.cancel()
        #expect(model.store.themes.count == count && model.settings.codeThemeLight == "gloss")
        #expect(!FileManager.default.fileExists(atPath: model.store.folder.appendingPathComponent(draft.theme.id+".json").path))
    }
    @Test func themeEditorCancelRestoresLivePreview() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let saved = theme(); try model.store.save(saved); model.select(saved,for: .light)
        model.edit(.light)
        let draft = try #require(model.draft); draft.theme.editor.background = ThemeColor("#223344")!
        #expect(ActiveCodeTheme.light.editor.background == draft.theme.editor.background)
        #expect(model.store.theme(id: saved.id) == saved)
        model.cancel()
        #expect(ActiveCodeTheme.light == saved)
    }
    @Test func themeSaveFailureKeepsDraft() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        model.duplicate(.dark)
        let draft = try #require(model.draft); draft.theme.name = "Keep my draft"
        model.saveFile = { _ in throw CodeThemeError.malformed("Fixture disk failure") }
        #expect(!model.save() && model.draft === draft)
        #expect(draft.theme.name == "Keep my draft" && draft.error?.contains("Couldn't save") == true)
        #expect(model.settings.codeThemeDark == "gloss")
    }
    @Test func missingThemeFallsBackPerAppearanceAndRecoversWithoutChangingItsId() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let light = theme(), dark = theme("fixture-dark",appearance: .dark)
        try model.store.save(light); try model.store.save(dark)
        model.select(light,for: .light); model.select(dark,for: .dark)
        try Data("broken theme".utf8).write(to: model.store.folder.appendingPathComponent(light.id+".json"))
        model.store.reload(); model.apply()
        #expect(ActiveCodeTheme.light.id == "gloss" && ActiveCodeTheme.dark.id == dark.id)
        #expect(model.settings.codeThemeLight == light.id && model.notice(.light)?.contains(light.name) == true)
        try model.store.save(light); model.apply()
        #expect(ActiveCodeTheme.light == light && model.notice(.light) == nil)
    }
    @Test func externalThemeChangePreservesOpenDraftAndCancelUsesCurrentFile() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let original = theme(); try model.store.save(original); model.select(original,for: .light); model.edit(.light)
        let draft = try #require(model.draft); draft.theme.name = "Unsaved name"
        var external = original; external.name = "External name"
        try model.store.save(external); model.apply()
        #expect(draft.externalChanged && draft.theme.name == "Unsaved name")
        #expect(!model.save() && model.store.theme(id: original.id) == external)
        model.cancel()
        #expect(ActiveCodeTheme.light == external)
    }
    @Test func savingDetectsAnExternalWriteBeforeTheWatcherReloads() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let original = theme(); try model.store.save(original); model.select(original,for: .light); model.edit(.light)
        let draft = try #require(model.draft); draft.theme.name = "Unsaved draft"
        var external = original; external.name = "External file"
        let url = model.store.folder.appendingPathComponent(original.id+".json")
        try external.encoded().write(to: url,options: .atomic)
        #expect(model.store.theme(id: original.id) == original)
        #expect(!model.save() && draft.externalChanged && model.draft === draft)
        #expect(try CodeTheme.decode(Data(contentsOf: url)) == external)
        model.cancel()
        #expect(ActiveCodeTheme.light == external)
    }
    @Test func externalConflictCanSaveACopyWithoutOverwritingTheChangedFile() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let original = theme(); try model.store.save(original); model.select(original,for: .light); model.edit(.light)
        let draft = try #require(model.draft); draft.theme.name = "My edit"
        var external = original; external.name = "External edit"; try model.store.save(external)
        #expect(model.save(asCopy: true))
        #expect(model.store.theme(id: original.id) == external && model.settings.codeThemeLight != original.id)
        #expect(model.settings.codeThemeDark == "gloss")
    }
    @Test func importNeverOverwritesExistingThemeIdentityAndCancelSavesNothing() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let input = folder.appendingPathComponent("example.json")
        try CodeTheme.gloss.encoded().write(to: input)
        await model.importFile(input)
        let draft = try #require(model.draft)
        #expect(draft.theme.id != "gloss" && draft.theme.id.hasPrefix("user-"))
        #expect(model.store.theme(id: draft.theme.id) == nil)
        model.cancel()
        await model.importFile(input)
        let importedID = try #require(model.draft?.theme.id)
        #expect(model.save() && model.store.theme(id: importedID) != nil)
        #expect(model.settings.codeThemeLight == importedID && model.settings.codeThemeDark == "gloss")
        #expect(model.store.theme(id: "gloss") == .gloss)
    }
    @Test func importRejectsOversizedOrInvalidInputWithoutChangingSelection() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let input = folder.appendingPathComponent("example.json")
        try Data(repeating: 0,count: CodeTheme.maximumFileSize+1).write(to: input)
        await model.importFile(input)
        #expect(model.draft == nil && model.error != nil && model.settings.codeThemeLight == "gloss")
        try Data("invalid".utf8).write(to: input)
        await model.importFile(input)
        #expect(model.draft == nil && model.settings.codeThemeLight == "gloss")
    }
    @Test func contrastWarningsDoNotBlockSave() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        model.duplicate(.light)
        let draft = try #require(model.draft)
        draft.theme.editor.background = ThemeColor("#FFFFFF")!; draft.theme.editor.foreground = ThemeColor("#EEEEEE")!
        #expect(!draft.theme.contrastIssues().isEmpty)
        let id = draft.theme.id
        #expect(model.save() && model.store.theme(id: id) != nil)
    }
    @Test func editingAPrimaryTokenKeepsOtherEditableRowsAndTheirAliases() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let original = theme(); try model.store.save(original); model.select(original,for: .light); model.edit(.light)
        let draft = try #require(model.draft)
        draft.theme.tokens["punctuation.special"] = TokenStyle(color: ThemeColor("#123456"),italic: true)
        draft.theme.tokens["variable.builtin"] = TokenStyle(color: ThemeColor("#456789"),bold: true)
        draft.theme.tokens["markup.link.label"] = TokenStyle(color: ThemeColor("#789ABC"))
        draft.theme.tokens["text.reference"] = TokenStyle(color: ThemeColor("#ABCDEF"),italic: true)
        let protected = draft.theme.tokens
        for key in ["punctuation","variable","markup.link"] { draft.setTokenStyle(TokenStyle(color: ThemeColor("#AA2222")),forKey: key) }
        for key in ["punctuation.special","variable.builtin","markup.link.label","text.reference"] {
            #expect(draft.theme.tokens[key] == protected[key] && ActiveCodeTheme.light.tokens[key] == protected[key])
        }
    }
    @Test func conflictQuotesLeaveMutedGlossAndLargeBlocksPlain() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        let lines = ["let value = 1","// unchanged"]
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        #expect(ConflictCodeLines.highlightedLines(lines,language: "swift",muted: false,appearance: .aqua).isEmpty)
        var palette = theme(); palette.tokens["keyword"] = TokenStyle(color: ThemeColor("#992200"),bold: true)
        ActiveCodeTheme.set(light: palette,dark: palette)
        #expect(ConflictCodeLines.highlightedLines(lines,language: "swift",muted: true,appearance: .aqua).isEmpty)
        let styled = ConflictCodeLines.highlightedLines(lines,language: "swift",muted: false,appearance: .aqua)
        #expect(styled.count == lines.count && String(styled[0].characters) == lines[0])
        #expect(styled[0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(ConflictCodeLines.highlightedLines(Array(repeating: lines[0],count: 1000),language: "swift",muted: false,appearance: .aqua).isEmpty)
    }
    @Test func deletingAUserThemeResetsEveryAffectedSlot() async throws {
        let (model,folder) = try await fixture(); defer { close(model,folder) }
        let shared = theme(appearance: .any); try model.store.save(shared)
        model.select(shared,for: .light); model.select(shared,for: .dark)
        // Production deletion may trash files; fixtures must only remove their own temporary file.
        model.deleteFile = { id in
            try FileManager.default.removeItem(at: model.store.folder.appendingPathComponent(id+".json"))
            model.store.reload()
        }
        model.delete(.light)
        #expect(model.settings.codeThemeLight == "gloss" && model.settings.codeThemeDark == "gloss")
        #expect(model.store.theme(id: shared.id) == nil)
    }
}
