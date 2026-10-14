import SwiftUI
import Viewers

/// Code quoted on a system surface uses the palette's colors and traits, keeping the caller's UI font and size.
struct CodeQuote: View {
    let text: String
    var language: String?
    @Environment(\.colorScheme) private var appearance
    @State private var styled: AttributedString?
    var body: some View {
        Text(styled ?? AttributedString(text))
            .task(id: CodeSnippetKey(text,language: language,dark: appearance == .dark)) {
                styled = SyntaxTheme.highlighted(text,language: language,appearance: appearance == .dark ? .darkAqua : .aqua)
            }
    }
}
