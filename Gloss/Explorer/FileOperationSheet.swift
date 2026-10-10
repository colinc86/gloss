import Core
import Observation
import SwiftUI

@MainActor @Observable
final class FileNameRequest: Identifiable {
    let id = UUID()
    let title: String
    let actionTitle: String
    let directory: String
    var name: String
    var error: String?
    var isSubmitting = false
    private let operation: (String) async throws -> Void

    init(title: String, actionTitle: String, name: String, directory: String, operation: @escaping (String) async throws -> Void) {
        self.title = title; self.actionTitle = actionTitle; self.name = name; self.directory = directory
        self.operation = operation
    }

    func submit() async -> Bool {
        guard !isSubmitting else { return false }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
            error = "Enter a filename without slashes. The names . and .. are reserved."
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do { try await operation(value); return true }
        catch FileSystemError.alreadyExists { error = "That name already exists. Choose a different name." }
        catch FileSystemError.permissionDenied { error = "You don't have permission to change this folder." }
        catch { self.error = "Couldn't \(actionTitle.lowercased()): \(error.userMessage)" }
        return false
    }
}

struct FileOperationSheet: View {
    @Bindable var request: FileNameRequest
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(request.directory).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $request.name).focused($focused).disabled(request.isSubmitting)
            if let error = request.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                if request.isSubmitting { ProgressView().controlSize(.small) }
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).disabled(request.isSubmitting)
                Button(request.actionTitle) {
                    Task { if await request.submit() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction).disabled(request.isSubmitting)
            }
        }
        .padding(20).frame(width: 400)
        .interactiveDismissDisabled(request.isSubmitting)
        .onAppear { focused = true }
    }
}
