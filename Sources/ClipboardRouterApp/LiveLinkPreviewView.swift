import AppKit
import ClipboardRouterPlatform
import SwiftUI

enum LiveLinkPreviewAccessibility {
    static let cardIdentifier = "uiAcceptance.livePreview.card"
    static let stateIdentifier = "uiAcceptance.livePreview.state"
    static let loadIdentifier = "uiAcceptance.livePreview.load"
    static let removeIdentifier = "uiAcceptance.livePreview.remove"
    static let refreshIdentifier = "uiAcceptance.livePreview.refresh"

    static func stateValue(for state: LiveLinkPreviewState) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .blocked: "blocked"
        case .offline: "offline"
        case .failed: "failed"
        }
    }
}

struct LiveLinkPreviewCard: View {
    let descriptor: StoredLinkPreviewDescriptor
    let clip: PresentedClip
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            liveContent
            Text(descriptor.displayURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            controls
        }
        .padding(16)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link preview for \(descriptor.title), \(descriptor.host)")
        .accessibilityIdentifier(LiveLinkPreviewAccessibility.cardIdentifier)
        .accessibilityValue(LiveLinkPreviewAccessibility.stateValue(for: state))
    }

    private var state: LiveLinkPreviewState {
        model.liveLinkPreviewState(for: clip)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.metadata?.title ?? descriptor.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(state.metadata?.siteName ?? descriptor.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Link(destination: descriptor.url) {
                Label("Open Link", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens the stored web address in your default browser")
        }
    }

    private var liveContent: some View {
        Group {
            switch state {
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    Label("No network request has been made.", systemImage: "network")
                        .foregroundStyle(.secondary)
                    Button("Load Preview") {
                        Task { await model.loadLiveLinkPreview(for: clip) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canLoadLiveLinkPreview(for: clip))
                    .accessibilityIdentifier(LiveLinkPreviewAccessibility.loadIdentifier)
                }
            case .loading:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading preview…")
                }
                .foregroundStyle(.secondary)
            case let .loaded(metadata):
                if let imageData = metadata.imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel("Website preview image")
                }
                if let summary = metadata.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
                Text("Fetched after selection · \(metadata.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case let .blocked(message):
                stateMessage(message, symbol: "hand.raised.fill", color: .orange)
            case let .offline(message):
                stateMessage(message, symbol: "wifi.slash", color: .secondary)
            case let .failed(message):
                stateMessage(message, symbol: "exclamationmark.triangle", color: .secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LiveLinkPreviewAccessibility.stateIdentifier)
        .accessibilityValue(LiveLinkPreviewAccessibility.stateValue(for: state))
    }

    private var controls: some View {
        HStack {
            Text("Live metadata is fetched only after Load Preview or Refresh. It never changes the clip.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Remove Preview") {
                Task { await model.clearLiveLinkPreview(for: clip) }
            }
            .controlSize(.small)
            .disabled(state == .idle)
            .accessibilityIdentifier(LiveLinkPreviewAccessibility.removeIdentifier)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.loadLiveLinkPreview(for: clip, refresh: true) }
            }
            .controlSize(.small)
            .disabled(!model.canLoadLiveLinkPreview(for: clip) || state == .loading)
            .accessibilityIdentifier(LiveLinkPreviewAccessibility.refreshIdentifier)
        }
    }

    private func stateMessage(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
