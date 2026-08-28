import SwiftUI

struct OnboardingView: View {
    let isEngineeringBuild: Bool
    let onComplete: () -> Void
    @State private var page = 0

    private let pages = [
        OnboardingPage(
            symbol: "magnifyingglass",
            tint: .blue,
            eyebrow: "FIND IT FAST",
            title: "Your clipboard, ready when you are",
            message: "Search recent clips from the menu bar or Library, then copy or paste in one step. Clipboard Router starts with new copies; it does not import what was already on your clipboard."
        ),
        OnboardingPage(
            symbol: "note.text.badge.plus",
            tint: .indigo,
            eyebrow: "KEEP THE CONTEXT",
            title: "Turn useful clips into working memory",
            message: "Save clips, turn them into editable notes, add shortcuts, and organize them with tags and nested folders. A Sales Workspace can create a ready-made research structure."
        ),
        OnboardingPage(
            symbol: "lock.shield.fill",
            tint: .green,
            eyebrow: "PROTECT SENSITIVE WORK",
            title: "Local-first, with a Vault when needed",
            message: "Pause capture, exclude private apps, or start a Private Session at any time. Secret-like clips are flagged for review, and Vault items stay outside ordinary search and sync."
        ),
        OnboardingPage(
            symbol: "person.2.badge.gearshape",
            tint: .teal,
            eyebrow: "SHARE AND ACT",
            title: "Move context into the next step",
            message: "Export reviewed handoffs, collaborate in shared folders when iCloud is available, or explicitly run a custom action. Assistant and Copy & Open stay optional and never submit content for you."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 22) {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(item.tint.opacity(0.12))
                                .frame(width: 112, height: 112)
                            Image(systemName: item.symbol)
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(item.tint)
                        }
                        Text(item.eyebrow)
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(item.tint)
                        Text(item.title)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(item.message)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .frame(maxWidth: 510)
                        Spacer()
                    }
                    .padding(44)
                    .tag(index)
                }
            }
            .tabViewStyle(.automatic)

            Divider()

            DirectLicenseOnboardingStatusView(isEngineeringBuild: isEngineeringBuild)
                .padding(.top, 12)

            HStack {
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                            .animation(.snappy, value: page)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Button(page == pages.count - 1 ? "Start Capturing" : "Continue") {
                    if page == pages.count - 1 {
                        onComplete()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 690, height: 590)
        .accessibilityElement(children: .contain)
    }
}

private struct OnboardingPage {
    let symbol: String
    let tint: Color
    let eyebrow: String
    let title: String
    let message: String
}
