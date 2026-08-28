import ClipboardRouterCore
import SwiftUI

struct NoteEditorRequest: Identifiable {
    enum Mode {
        case create
        case makeFromClip(PresentedClip)
        case edit(PresentedClip)
    }

    let id = UUID()
    let mode: Mode
}

struct ClipEditorRequest: Identifiable {
    enum Mode {
        case editSaved(PresentedClip)
        case editHistoryCopy(PresentedClip)
    }

    let id = UUID()
    let mode: Mode

    var clip: PresentedClip {
        switch mode {
        case let .editSaved(clip), let .editHistoryCopy(clip): clip
        }
    }
}

struct NoteEditorSheet: View {
    let request: NoteEditorRequest
    let folders: [FolderDestination]
    let save: (String, String, UUID?) async -> Bool
    let explicitDismiss: (() -> Void)?
    let explicitSaveCompletion: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var folderID: UUID?
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool

    init(
        request: NoteEditorRequest,
        folders: [FolderDestination],
        dismiss: (() -> Void)? = nil,
        saved: (() -> Void)? = nil,
        save: @escaping (String, String, UUID?) async -> Bool
    ) {
        self.request = request
        self.folders = folders
        explicitDismiss = dismiss
        explicitSaveCompletion = saved
        self.save = save
        switch request.mode {
        case .create:
            _title = State(initialValue: "")
            _bodyText = State(initialValue: "")
            _folderID = State(initialValue: nil)
        case let .makeFromClip(clip):
            _title = State(initialValue: clip.title)
            _bodyText = State(initialValue: clip.content.text)
            _folderID = State(initialValue: clip.origin.savedFolderID)
        case let .edit(clip):
            _title = State(initialValue: clip.title)
            _bodyText = State(initialValue: clip.content.text)
            if case let .saved(existingFolderID) = clip.origin {
                _folderID = State(initialValue: existingFolderID)
            } else {
                _folderID = State(initialValue: nil)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editorTitle)
                .font(.title2.weight(.semibold))
            if isMakingFromClip {
                Label(
                    "Creates a new editable note. Your original clip stays unchanged.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note title")
                .accessibilityIdentifier("uiAcceptance.noteEditor.title")
                .focused($titleFocused)
            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write your note…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $bodyText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityLabel("Note body. Markdown text is supported.")
                    .accessibilityIdentifier("uiAcceptance.noteEditor.body")
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 220, idealHeight: 260, maxHeight: .infinity)
            Picker("Folder", selection: $folderID) {
                Text("Saved").tag(UUID?.none)
                ForEach(folders) { folder in
                    Text(folder.path).tag(Optional(folder.id))
                        .disabled(!folder.canAcceptItems)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plain-text Markdown stays local unless you explicitly sync or share its folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(isEditing ? "Save Note" : "Create Note") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || trimmedTitle.isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .overlay { if isSaving { ProgressView().controlSize(.small) } }
                .accessibilityIdentifier("uiAcceptance.noteEditor.save")
            }
        }
        .padding(22)
        .frame(
            minWidth: 520,
            idealWidth: 560,
            maxWidth: .infinity,
            minHeight: 430,
            idealHeight: 470,
            maxHeight: .infinity
        )
        .onAppear { titleFocused = true }
        .interactiveDismissDisabled(isSaving)
    }

    private var isEditing: Bool {
        if case .edit = request.mode { return true }
        return false
    }

    private var isMakingFromClip: Bool {
        if case .makeFromClip = request.mode { return true }
        return false
    }

    private var editorTitle: String {
        if isEditing { return "Edit Note" }
        if isMakingFromClip { return "Make an Editable Note" }
        return "New Note"
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        saveError = nil
        isSaving = true
        Task {
            let succeeded = await save(trimmedTitle, bodyText, folderID)
            isSaving = false
            if succeeded {
                completeSave()
            } else {
                saveError = "Couldn’t save. Your draft is still here; review the warning and try again."
            }
        }
    }

    private func close() {
        if let explicitDismiss {
            explicitDismiss()
        } else {
            dismiss()
        }
    }

    private func completeSave() {
        if let explicitSaveCompletion {
            explicitSaveCompletion()
        } else {
            close()
        }
    }
}

struct ClipEditorSheet: View {
    let request: ClipEditorRequest
    let folders: [FolderDestination]
    let save: (String, String, UUID?) async -> Bool
    let explicitDismiss: (() -> Void)?
    let explicitSaveCompletion: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var folderID: UUID?
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        request: ClipEditorRequest,
        folders: [FolderDestination],
        dismiss: (() -> Void)? = nil,
        saved: (() -> Void)? = nil,
        save: @escaping (String, String, UUID?) async -> Bool
    ) {
        self.request = request
        self.folders = folders
        explicitDismiss = dismiss
        explicitSaveCompletion = saved
        self.save = save
        let clip = request.clip
        _title = State(initialValue: clip.title)
        _bodyText = State(initialValue: clip.content.text)
        if case let .saved(existingFolderID) = clip.origin {
            _folderID = State(initialValue: existingFolderID)
        } else {
            _folderID = State(initialValue: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(createsEditableCopy ? "Edit a Saved Copy" : "Edit Clip")
                .font(.title2.weight(.semibold))
            Label(explanation, systemImage: createsEditableCopy ? "clock.arrow.circlepath" : "pencil")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Clip name", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Clip name")
                .accessibilityIdentifier("uiAcceptance.clipEditor.title")
            TextEditor(text: $bodyText)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 220, idealHeight: 260, maxHeight: .infinity)
                .accessibilityLabel("Editable clip content")
                .accessibilityIdentifier("uiAcceptance.clipEditor.body")
            Picker("Folder", selection: $folderID) {
                Text("Saved").tag(UUID?.none)
                ForEach(folders) { folder in
                    Text(folder.path).tag(Optional(folder.id))
                        .disabled(!folder.canAcceptItems)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plain text and links update in place. Rich text creates a new editable plain-text copy so the formatted original stays intact. Images and files are not editable here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(createsEditableCopy ? "Save Copy" : "Save Changes") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || trimmedTitle.isEmpty || trimmedBody.isEmpty)
                .overlay { if isSaving { ProgressView().controlSize(.small) } }
                .accessibilityIdentifier("uiAcceptance.clipEditor.save")
            }
        }
        .padding(22)
        .frame(
            minWidth: 540,
            idealWidth: 590,
            maxWidth: .infinity,
            minHeight: 450,
            idealHeight: 500,
            maxHeight: .infinity
        )
        .interactiveDismissDisabled(isSaving)
    }

    private var isHistoryCopy: Bool {
        if case .editHistoryCopy = request.mode { return true }
        return false
    }

    private var createsEditableCopy: Bool {
        isHistoryCopy || request.clip.content.type == .richText
    }

    private var explanation: String {
        createsEditableCopy
            ? "The original stays unchanged. Your edits become a new saved plain-text clip."
            : "This updates the saved clip while preserving its source metadata, pin, and folder."
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        saveError = nil
        isSaving = true
        Task {
            let succeeded = await save(trimmedTitle, bodyText, folderID)
            isSaving = false
            if succeeded {
                completeSave()
            } else {
                saveError = "Couldn’t save. Your draft is still here; review the warning and try again."
            }
        }
    }

    private func close() {
        if let explicitDismiss {
            explicitDismiss()
        } else {
            dismiss()
        }
    }

    private func completeSave() {
        if let explicitSaveCompletion {
            explicitSaveCompletion()
        } else {
            close()
        }
    }
}
