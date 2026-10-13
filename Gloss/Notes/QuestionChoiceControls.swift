import Core
import SwiftUI

/// Native controls keep keyboard and accessibility selection semantics. Selection only stages text.
struct QuestionChoiceControls: View {
    @Environment(AppModel.self) private var model
    let question: NoteMessage
    let choices: QuestionChoices
    let editable: Bool
    private var selected: [Int] {
        model.notesPanel.selectedChoices(for: question, editable: editable)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if choices.multi {
                Text("Choose any that apply").font(.caption).foregroundStyle(.secondary)
                ForEach(choices.options.indices, id: \.self) { index in
                    Toggle(isOn: Binding(get: { selected.contains(index) }, set: { on in
                        let indexes = on ? selected + [index] : selected.filter { $0 != index }
                        Task { await model.notesPanel.selectChoices(indexes, question: question.id) }
                    })) { label(index) }.toggleStyle(.checkbox)
                }
            } else {
                Picker("Choose one", selection: Binding<Int?>(get: { selected.first }, set: { index in
                    Task { await model.notesPanel.selectChoices(index.map { [$0] } ?? [], question: question.id) }
                })) {
                    ForEach(choices.options.indices, id: \.self) { index in label(index).tag(Optional(index)) }
                }.pickerStyle(.radioGroup)
            }
            if !selected.isEmpty, editable {
                HStack {
                    Text("Your answer · Not sent").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear choices") { Task { await model.notesPanel.selectChoices([], question: question.id) } }.buttonStyle(.plain)
                }
            }
        }
        .disabled(!editable)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question.body). \(choices.multi ? "Choose any that apply" : "Choose one")")
    }
    private func label(_ index: Int) -> some View {
        Text(choices.options[index]).lineLimit(nil).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
    }
}
