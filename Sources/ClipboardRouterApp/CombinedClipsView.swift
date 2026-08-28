import ClipboardRouterCore
import SwiftUI

struct CombinedClipsReviewSheet: View {
    @ObservedObject var model: AppModel
    let request: CombinedClipsReviewRequest
    @State private var preview = ""
    @State private var isShowingAssistant = false
    @State private var isSavingNote = false

    var body: some View {
        Group {
            if isShowingAssistant {
                AIClipAssistantSheet(
                    availability: model.onDeviceAIAvailability,
                    cloudConfigured: model.isHostedAssistantConfigured,
                    cloudConsentGranted: model.isHostedAssistantConsentGranted,
                    cloudModel: model.hostedAssistantModel,
                    cloudSourceEligible: model.canUseCloudAssistant(for: request),
                    cloudSourceUnavailableReason: model.cloudAssistantUnavailableReason(for: request),
                    sourceTitle: "\(request.pack.items.count) combined clip\(request.pack.items.count == 1 ? "" : "s")",
                    ask: { prompt, messages, purpose, engine in
                        await model.askCombinedClipsAssistant(
                            prompt: prompt,
                            messages: messages,
                            purpose: purpose,
                            engine: engine,
                            request: request
                        )
                    },
                    saveResult: { result, provenance in
                        await model.saveCombinedClipsAIDraft(
                            result,
                            request: request,
                            modelProvenance: provenance
                        )
                    },
                    copyResult: model.copyAssistantResponse,
                    errorMessage: Binding(
                        get: { model.errorMessage },
                        set: { model.errorMessage = $0 }
                    ),
                    cancel: { isShowingAssistant = false }
                )
            } else {
                reviewContent
            }
        }
        .onAppear {
            preview = model.combinedClipsMarkdown(for: request) ?? ""
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Combine Clips")
                        .font(.title2.weight(.semibold))
                    Text(reviewSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.dismissCombinedClipsReview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Combine Clips")
            }
            .padding(16)

            Divider()

            HSplitView {
                List(Array(request.pack.items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(index + 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(item.title)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Clip \(index + 1), \(item.title)")
                }
                .listStyle(.inset)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

                ScrollView {
                    Text(preview)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Combined clips preview")
            }

            Divider()

            HStack(spacing: 10) {
                Button("Clear Collection", role: .destructive) {
                    model.clearCombinedClips()
                }
                Spacer()
                Button("Share…", systemImage: "square.and.arrow.up") {
                    model.shareCombinedClips(request)
                }
                Button("Save as Note", systemImage: "note.text.badge.plus") {
                    guard !isSavingNote else { return }
                    isSavingNote = true
                    Task {
                        _ = await model.saveCombinedClipsAsNote(request)
                        isSavingNote = false
                    }
                }
                .disabled(isSavingNote || model.isBusy)
                Button("Use AI", systemImage: "sparkles") {
                    isShowingAssistant = true
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    model.copyCombinedClips(request)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(14)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 460, idealHeight: 520)
    }

    private var reviewSubtitle: String {
        if request.pack.items.count == 1 {
            return "Review 1 clip before using it."
        }
        return "Review \(request.pack.items.count) clips before using them together."
    }
}
