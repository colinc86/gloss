import AppKit
import SwiftUI
import Viewers

private enum ThemeEditorTab: String,CaseIterable,Identifiable {
    case tokens = "Tokens", editor = "Editor", font = "Font"
    var id: String { rawValue }
}
private enum EditorColorField: String,CaseIterable,Identifiable {
    case background = "Background", foreground = "Foreground", selection = "Selection", currentLine = "Current Line"
    case gutter = "Gutter Background", numbers = "Line Numbers", currentNumber = "Current Line Number", invisibles = "Invisibles", cursor = "Caret", codeBlock = "Code Block Background"
    var id: String { rawValue }
    var key: WritableKeyPath<EditorColors,ThemeColor> {
        switch self {
        case .background: \.background; case .foreground: \.foreground; case .selection: \.selection; case .currentLine: \.currentLine
        case .gutter: \.gutterBackground; case .numbers: \.lineNumbers; case .currentNumber: \.currentLineNumber; case .invisibles: \.invisibles; case .cursor: \.cursor; case .codeBlock: \.codeBlockBackground
        }
    }
}

struct ThemeEditor: View {
    @Bindable var model: ThemesModel
    @Bindable var draft: ThemeDraft
    @State private var tab = ThemeEditorTab.tokens
    @State private var token = "keyword"
    @State private var previewMode = ThemePreviewMode.code
    @State private var replacing = false
    @FocusState private var nameFocused: Bool
    private var slot: ThemeSlot { draft.theme.appearance == .dark ? .dark : .light }
    private var primary: [(key: String,label: String)] {
        CodeTheme.editableTokens.map { ($0.key,$0.label) }
    }
    private var additional: [String] { draft.theme.tokens.keys.filter { key in !primary.contains { $0.key == key } }.sorted() }
    var body: some View {
        let warnings = draft.theme.contrastIssues()
        VStack(alignment: .leading,spacing: DS.Space.m) {
            Text(draft.title).font(.title2.weight(.semibold))
            HStack {
                TextField("Name",text: $draft.theme.name).focused($nameFocused)
                Picker("Appearance",selection: $draft.theme.appearance) {
                    Text("Light").tag(CodeTheme.Appearance.light); Text("Dark").tag(CodeTheme.Appearance.dark)
                }.frame(width: 170)
            }
            if let report = draft.report {
                DisclosureGroup(report.summary) {
                    Text(report.mappedTokens == 0 ? "No token styles mapped. Unmapped tokens use Foreground." : "Unmapped tokens use Foreground.")
                    ForEach(report.unmappedScopes,id: \.self) { Text($0).font(.caption.monospaced()) }
                    ForEach(report.skipped,id: \.self) { Text($0).font(.caption) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                VStack(alignment: .leading,spacing: DS.Space.s) {
                    Picker("Controls",selection: $tab) { ForEach(ThemeEditorTab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    switch tab {
                    case .tokens: tokenEditor(warnings: warnings)
                    case .editor: editorColors
                    case .font: fontEditor
                    }
                }.frame(minWidth: 300,idealWidth: 340,maxWidth: 460)
                VStack(alignment: .leading,spacing: DS.Space.s) {
                    Picker("Preview",selection: $previewMode) { ForEach(ThemePreviewMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    ThemePreview(theme: draft.theme,slot: slot,mode: previewMode,defaultSize: model.settings.fontSize)
                    if !draft.theme.selectionClashes().isEmpty {
                        Text("Selection resembles a note fill. The editor uses a distinct tint.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading,DS.Space.m).frame(minWidth: 300)
            }
            if draft.externalChanged {
                Label("This theme changed outside Gloss.",systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading,spacing: DS.Space.xxs) {
                    if let license = draft.theme.license {
                        DisclosureGroup("Source and license") { ScrollView { Text(license).font(.caption).textSelection(.enabled) }.frame(maxHeight: 110) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(warnings.isEmpty ? "No low-contrast token colors." : "\(Set(warnings.map(\.key)).count) colors may be hard to read.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button(draft.kind == .imported ? "Add Theme" : (draft.error == nil ? "Save" : "Try Again")) {
                    if draft.externalChanged || !model.save() && draft.externalChanged { replacing = true }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(draft.theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.invalidFields.isEmpty)
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 760,idealWidth: 760,maxWidth: 1100,minHeight: 580,idealHeight: 580,maxHeight: 900)
        .onAppear { nameFocused = true }
        .confirmationDialog("This theme changed outside Gloss.",isPresented: $replacing,titleVisibility: .visible) {
            Button("Replace File") { model.save(replacing: true) }
            Button("Save a Copy") { model.save(asCopy: true) }
            Button("Cancel",role: .cancel) {}
        } message: { Text("Keep your draft and choose how to save it. Canceling the editor loads the current file.") }
    }
    private func tokenEditor(warnings: [ContrastIssue]) -> some View {
        VStack(alignment: .leading,spacing: DS.Space.s) {
            List(selection: $token) {
                ForEach(primary,id: \.key) { row in
                    HStack {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: draft.theme.style(forCapture: row.key)?.color?.nsColor ?? draft.theme.editor.foreground.nsColor)).frame(width: 12,height: 12).accessibilityHidden(true)
                        Text(row.label)
                        Spacer()
                        if let issue = warnings.first(where: { $0.key == row.key }) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).help("Low contrast · \(issue.ratio.formatted(.number.precision(.fractionLength(1)))):1")
                        }
                    }.tag(row.key)
                }
                if !additional.isEmpty {
                    DisclosureGroup("Additional token styles") {
                        ForEach(additional,id: \.self) { Text($0).font(.caption).tag($0) }
                    }
                }
            }.frame(minHeight: 170)
            let style = Binding<TokenStyle>(get: { draft.theme.style(forCapture: token) ?? TokenStyle(color: nil) },set: { value in
                draft.setTokenStyle(value,forKey: token)
            })
            ThemeColorControl(label: primary.first { $0.key == token }?.label ?? token,
                              value: Binding(get: { style.wrappedValue.color },set: { value in var changed = style.wrappedValue; changed.color = value; style.wrappedValue = changed }),
                              inherited: draft.theme.editor.foreground,background: draft.theme.editor.background,appearance: slot.appearance,
                              minimum: 3,validation: { valid in validate("token",valid: valid) })
                .id(token)
            HStack {
                Toggle("Bold",isOn: Binding(get: { style.wrappedValue.bold },set: { var value = style.wrappedValue; value.bold = $0; style.wrappedValue = value }))
                Toggle("Italic",isOn: Binding(get: { style.wrappedValue.italic },set: { var value = style.wrappedValue; value.italic = $0; style.wrappedValue = value }))
            }.toggleStyle(.checkbox)
        }
    }
    private var editorColors: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: DS.Space.m) {
                ForEach(EditorColorField.allCases) { field in
                    ThemeColorControl(label: field.rawValue,value: Binding(get: { draft.theme.editor[keyPath: field.key] },set: { if let value = $0 { draft.theme.editor[keyPath: field.key] = value } }),
                                      inherited: draft.theme.editor.foreground,background: field == .numbers ? draft.theme.editor.gutterBackground : draft.theme.editor.background,
                                      appearance: slot.appearance,minimum: field == .foreground ? 4.5 : (field == .numbers ? 3 : nil),allowsReset: false,
                                      validation: { valid in validate(field.id,valid: valid) })
                }
            }.padding(.vertical,DS.Space.s)
        }
    }
    private var fontEditor: some View {
        Form {
            Picker("Family",selection: Binding(get: { draft.theme.font.family ?? "" },set: { draft.theme.font.family = $0.isEmpty ? nil : $0 })) {
                Text("System Monospaced").tag("")
                if let family = draft.theme.font.family, !NSFontManager.shared.availableFontFamilies.contains(family) { Text(family).tag(family) }
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(),id: \.self) { Text($0).tag($0) }
            }
            ThemeNumberControl(label: "Size",value: $draft.theme.font.size,range: SettingsStore.fontSizeRange,defaultValue: model.settings.fontSize,suffix: "pt",validation: { valid in validate("size",valid: valid) })
            ThemeNumberControl(label: "Line Spacing",value: $draft.theme.font.lineSpacing,range: 1...2,defaultValue: 1,suffix: "×",validation: { valid in validate("spacing",valid: valid) })
            if !draft.theme.font.isAvailable { Text("Font not installed. Using System Monospaced.").font(.caption).foregroundStyle(.secondary) }
            Text("Themes without a size use the font size in Editor settings.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
    private func validate(_ key: String,valid: Bool) {
        if valid { draft.invalidFields.remove(key) } else { draft.invalidFields.insert(key) }
    }
}

private struct ThemeColorControl: View {
    let label: String
    @Binding var value: ThemeColor?
    let inherited: ThemeColor
    let background: ThemeColor
    let appearance: NSAppearance.Name
    var minimum: Double?
    var allowsReset = true
    var validation: (Bool) -> Void = { _ in }
    @State private var text = ""
    private var displayed: ThemeColor { value ?? inherited }
    var body: some View {
        VStack(alignment: .leading,spacing: DS.Space.xxs) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                ColorPicker(label,selection: Binding(get: { Color(nsColor: displayed.nsColor) },set: { value = ThemeColor(NSColor($0)); text = displayed.description; validation(true) }),supportsOpacity: true)
                    .labelsHidden().accessibilityLabel("\(label) color")
                TextField("Hex",text: $text).font(.caption.monospaced()).frame(width: 116).accessibilityLabel("\(label) hex value")
                    .onChange(of: text) { _, text in
                        if let color = ThemeColor(text) { if !(value == nil && color == inherited), value != color { value = color }; validation(true) }
                        else { validation(false) }
                    }
            }
            if allowsReset {
                Button("Use Foreground") { value = nil; text = inherited.description; validation(true) }.font(.caption)
            }
            if let minimum, ThemeContrast.ratio(displayed.nsColor,background.nsColor,in: appearance) < minimum {
                let ratio = ThemeContrast.ratio(displayed.nsColor,background.nsColor,in: appearance)
                Label("Low contrast · \(ratio,specifier: "%.1f"):1",systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if !text.isEmpty, ThemeColor(text) == nil { Text("Enter a hex color, such as #AABBCC.").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { text = displayed.description }
        .onChange(of: displayed) { _, color in if ThemeColor(text) != color { text = color.description } }
    }
}

private struct ThemeNumberControl: View {
    let label: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let defaultValue: Double
    let suffix: String
    var validation: (Bool) -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                TextField(label,text: $text).frame(width: 65).accessibilityLabel(label)
                    .onChange(of: text) { _, text in
                        guard let number = Double(text), number.isFinite, range.contains(number) else { validation(false); return }
                        if !(value == nil && number == defaultValue), value != number { value = number }; validation(true)
                    }
                Text(suffix).foregroundStyle(.secondary)
            }
            Toggle("Use Default",isOn: Binding(get: { value == nil },set: { defaults in value = defaults ? nil : defaultValue; text = String(value ?? defaultValue); validation(true) }))
            if value != nil {
                Slider(value: Binding(get: { value ?? defaultValue },set: { value = $0; text = String($0); validation(true) }),in: range,step: 0.1)
            }
        }
        .onAppear { text = String(value ?? defaultValue) }
    }
}
