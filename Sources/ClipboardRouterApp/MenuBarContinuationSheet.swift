import SwiftUI

/// Host-neutral content for follow-up work started in MenuBarExtra. Its explicit dismissal
/// callback works both in the dedicated AppKit window and in visual-evidence SwiftUI hosts.
struct MenuBarContinuationSheet: View {
    @ObservedObject var model: AppModel
    let request: MenuBarContinuationRequest
    let dismiss: () -> Void
    let revealLibraryAfterSuccess: () -> Void
    @State private var quickPasteCreatesNote = false

    init(
        model: AppModel,
        request: MenuBarContinuationRequest,
        dismiss: @escaping () -> Void = {},
        revealLibraryAfterSuccess: @escaping () -> Void = {}
    ) {
        self.model = model
        self.request = request
        self.dismiss = dismiss
        self.revealLibraryAfterSuccess = revealLibraryAfterSuccess
    }

    @ViewBuilder
    var body: some View {
        switch request.action {
        case .quickPaste:
            if quickPasteCreatesNote {
                NoteEditorSheet(
                    request: NoteEditorRequest(mode: .create),
                    folders: model.folderDestinations,
                    dismiss: dismiss,
                    saved: revealLibraryAfterSuccess
                ) { title, body, folderID in
                    await model.createNoteFromEditor(
                        title: title,
                        body: body,
                        folderID: folderID
                    )
                }
            } else {
                InsertPaletteSheet(
                    model: model,
                    pasteTargetToken: model.insertPalettePasteTargetToken,
                    requestCreateNote: { quickPasteCreatesNote = true },
                    cancel: dismiss
                )
            }

        case let .noteEditor(editorRequest):
            NoteEditorSheet(
                request: editorRequest,
                folders: model.folderDestinations,
                dismiss: dismiss,
                saved: revealLibraryAfterSuccess
            ) {
                title, body, folderID in
                switch editorRequest.mode {
                case .create, .makeFromClip:
                    return await model.createNoteFromEditor(
                        title: title,
                        body: body,
                        folderID: folderID
                    )
                case let .edit(clip):
                    return await model.updateNoteFromEditor(
                        clip,
                        title: title,
                        body: body,
                        folderID: folderID
                    )
                }
            }

        case let .clipEditor(editorRequest):
            ClipEditorSheet(
                request: editorRequest,
                folders: model.folderDestinations,
                dismiss: dismiss,
                saved: revealLibraryAfterSuccess
            ) {
                title, body, folderID in
                await model.saveEditedClipFromEditor(
                    editorRequest.clip,
                    title: title,
                    body: body,
                    folderID: folderID
                )
            }

        case let .calendar(calendarRequest):
            CalendarEventDraftSheet(
                draft: calendarRequest.draft,
                save: { reviewed in
                    let saved = await model.createCalendarEvent(
                        reviewed,
                        sourceClip: calendarRequest.sourceClip
                    )
                    if saved { dismiss() }
                    return saved
                },
                cancel: dismiss
            )

        case let .newFolder(clip):
            MenuBarNewFolderSheet(dismiss: dismiss) { name in
                Task {
                    do {
                        try await model.saveHistoryClipInNewFolder(clip, named: name)
                        dismiss()
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }

        case let .vaultMove(clip, summary):
            MenuBarVaultMoveSheet(
                model: model,
                clip: clip,
                summary: summary,
                dismiss: dismiss
            )

        case let .shortcutEditor(clip):
            MenuBarInsertShortcutSheet(model: model, clip: clip, dismiss: dismiss)

        case let .encryptedShare(request):
            EncryptedShareComposerSheet(
                model: model,
                request: request,
                dismiss: dismiss
            )

        case let .sensitiveExport(clip, category):
            MenuBarSensitiveExportSheet(
                model: model,
                clip: clip,
                category: category,
                dismiss: dismiss
            )

        case let .newDeveloperProject(clip):
            DeveloperProjectEditorView(model: model, clipToAdd: clip) {
                dismiss()
            }

        case let .assistant(assistantRequest):
            AIClipAssistantSheet(
                availability: model.onDeviceAIAvailability,
                cloudConfigured: model.isHostedAssistantConfigured,
                cloudConsentGranted: model.isHostedAssistantConsentGranted,
                cloudModel: model.hostedAssistantModel,
                cloudSourceEligible: model.canUseCloudAssistant(for: assistantRequest.sourceClip),
                cloudSourceUnavailableReason: model.cloudAssistantUnavailableReason(for: assistantRequest.sourceClip),
                sourceTitle: assistantRequest.sourceClip.title,
                ask: { prompt, messages, purpose, engine in
                    await model.askAssistant(
                        prompt: prompt,
                        messages: messages,
                        purpose: purpose,
                        engine: engine,
                        sourceClip: assistantRequest.sourceClip
                    )
                },
                saveResult: {
                    await model.saveAIDraft(
                        $0,
                        sourceClip: assistantRequest.sourceClip,
                        modelProvenance: $1
                    )
                },
                copyResult: model.copyAssistantResponse,
                errorMessage: Binding(
                    get: { model.errorMessage },
                    set: { model.errorMessage = $0 }
                ),
                cancel: dismiss
            )

        case let .contact(contactRequest):
            ContactDraftSheet(
                draft: contactRequest.draft,
                checkDuplicates: model.contactDuplicates,
                save: { draft, allowDuplicate in
                    let saved = await model.createContact(
                        draft,
                        sourceClip: contactRequest.sourceClip,
                        allowingPossibleDuplicate: allowDuplicate
                    )
                    if saved { dismiss() }
                    return saved
                },
                cancel: dismiss
            )
        }
    }
}

private struct MenuBarVaultMoveSheet: View {
    @ObservedObject var model: AppModel
    let clip: PresentedClip
    let summary: VaultMoveSummary
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Move to Vault", systemImage: "lock")
                .font(.title2.weight(.semibold))
            Text(summary.confirmationMessage)
                .foregroundStyle(.secondary)
            Text("The encrypted Vault item is committed before ordinary copies are removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Move to Vault", role: .destructive) {
                    model.moveClipToVault(clip, confirmedSummary: summary)
                    dismiss()
                }
                .disabled(model.isBusy || !model.canMoveClipToVault(clip))
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct MenuBarSensitiveExportSheet: View {
    @ObservedObject var model: AppModel
    let clip: PresentedClip
    let category: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export sensitive clip?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)
            Text("This clip is marked as \(category). Export only to a trusted location.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Export Anyway", role: .destructive) {
                    dismiss()
                    Task { @MainActor in
                        await Task.yield()
                        model.exportOrdinaryClip(
                            clip,
                            sensitiveContentConfirmed: true,
                            confirmedSensitivityCategory: category
                        )
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
