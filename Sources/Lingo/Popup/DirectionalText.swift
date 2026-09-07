import SwiftUI

/// Selectable text block that flips layout direction and alignment for RTL
/// languages. Centralizes the layoutDirection/alignment/textSelection triple
/// that used to be copy-pasted per text block; direction comes from
/// `LanguageCatalog.isRTL` instead of a hardcoded language list.
struct DirectionalText: View {
    let text: String
    let languageCode: String?
    var font: Font = .body
    var color: Color = .primary
    var lineLimit: Int? = nil

    private var isRTL: Bool { LanguageCatalog.isRTL(languageCode) }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .textSelection(.enabled)
    }
}
