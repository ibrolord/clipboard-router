import SwiftUI

/// A compact, bounded empty-state card for detail and list panes.
///
/// `ContentUnavailableView` expands to fill its container, which reads as an oversized, empty
/// pane in a wide detail column and clips its description in a narrow one. This card keeps the
/// content at a readable measure, centers it in the available space, and scrolls when the pane is
/// short so a long message is never cut off by the bottom status toast.
struct EmptyStateCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var actions: () -> Actions

    /// Roughly a 60-character measure. Wider than this and the copy stops being scannable.
    private let maximumContentWidth: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if Actions.self != EmptyView.self {
                    // Vault's narrow list column cannot fit two full-width actions side by side.
                    // Prefer the compact horizontal treatment, then fall back to a vertical stack
                    // without truncating labels or reducing the hit target.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actions() }
                        VStack(spacing: 8) { actions() }
                    }
                    .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: maximumContentWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Distinguishes a sidebar row that performs an action from a row that navigates.
    ///
    /// A `.plain` button inside a sidebar `List` renders with the same weight and colour as a
    /// navigation `Label`, so a command reads as a destination. Tinting the row and dropping it
    /// to a lighter weight restores the distinction without leaving the sidebar idiom.
    func sidebarActionRow(tint: Color) -> some View {
        font(.callout.weight(.medium))
            .foregroundStyle(tint)
    }
}

extension EmptyStateCard where Actions == EmptyView {
    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color = .accentColor
    ) {
        self.init(
            title: title,
            message: message,
            systemImage: systemImage,
            tint: tint,
            actions: { EmptyView() }
        )
    }
}
