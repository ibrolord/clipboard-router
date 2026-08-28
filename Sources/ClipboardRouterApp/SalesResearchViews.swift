import ClipboardRouterCore
import SwiftUI

enum SalesResearchAccessibility {
    static let workspaceSheet = "uiAcceptance.sales.workspaceSheet"
    static let workspaceName = "uiAcceptance.sales.workspaceName"
    static let createWorkspace = "uiAcceptance.sales.createWorkspace"
    static let cancelWorkspace = "uiAcceptance.sales.cancelWorkspace"

    static let handoffReview = "uiAcceptance.sales.handoffReview"
    static let handoffSummary = "uiAcceptance.sales.handoffSummary"
    static let handoffFormat = "uiAcceptance.sales.handoffFormat"
    static let cancelHandoff = "uiAcceptance.sales.cancelHandoff"
    static let copyHandoff = "uiAcceptance.sales.copyHandoff"
    static let exportHandoff = "uiAcceptance.sales.exportHandoff"

    static func handoffSummaryValue(ready: Int, omitted: Int) -> String {
        "\(ready) ready, \(omitted) omitted"
    }
}

struct TagEditorSheet: View {
    let initialTags: [String]
    let save: ([String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(initialTags: [String], save: @escaping ([String]) async -> Bool) {
        self.initialTags = initialTags
        self.save = save
        _draft = State(initialValue: initialTags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Tags")
                .font(.title2.weight(.semibold))
            Text("Add up to \(ClipTag.maximumCountPerItem) tags. Separate tags with commas or new lines.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 120)
                .accessibilityLabel("Tags separated by commas or new lines")

            if case let .success(tags) = validatedTags, !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Tags are searchable with tag:name and are included in eligible handoff exports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
                Button("Save Tags") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || validationError != nil)
                    .overlay { if isSaving { ProgressView().controlSize(.small) } }
            }
        }
        .padding(22)
        .frame(width: 520, height: 360)
        .interactiveDismissDisabled(isSaving)
    }

    private var candidates: [String] {
        draft.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var validatedTags: Result<[String], Error> {
        Result { try ClipTag.normalize(candidates) }
    }

    private var validationError: String? {
        if case let .failure(error) = validatedTags { return error.localizedDescription }
        return nil
    }

    private func commit() {
        guard case let .success(tags) = validatedTags else { return }
        saveError = nil
        isSaving = true
        Task {
            let succeeded = await save(tags)
            isSaving = false
            if succeeded {
                dismiss()
            } else {
                saveError = "Couldn’t update the tags. Your changes are still here."
            }
        }
    }
}

struct NewSalesWorkspaceSheet: View {
    let create: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Sales Workspace")
                .font(.title2.weight(.semibold))
            Text("Start with a consistent structure for an account, campaign, or market segment.")
                .foregroundStyle(.secondary)

            TextField("Workspace name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Sales workspace name")
                .accessibilityIdentifier(SalesResearchAccessibility.workspaceName)

            GroupBox("Folders created") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(trimmedName.isEmpty ? "Workspace" : trimmedName, systemImage: "folder.fill")
                    ForEach(FolderRecipe.salesWorkspace(named: trimmedName).childNames, id: \.self) { child in
                        Label(child, systemImage: "arrow.turn.down.right")
                            .padding(.leading, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            HStack {
                Text("You can rename, nest, share, or drag items into these folders afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier(SalesResearchAccessibility.cancelWorkspace)
                Button("Create Workspace") {
                    create(trimmedName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier(SalesResearchAccessibility.createWorkspace)
                .accessibilityValue(trimmedName.isEmpty ? "Workspace name required" : trimmedName)
            }
        }
        .padding(22)
        .frame(width: 520, height: 390)
        .accessibilityIdentifier(SalesResearchAccessibility.workspaceSheet)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HandoffReviewSheet: View {
    let request: HandoffReviewRequest
    let copyMarkdown: (HandoffProjection) -> Void
    let export: (HandoffProjection, HandoffFormat) -> Void
    let cancel: () -> Void

    @State private var format = HandoffFormat.markdown

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Research Handoff")
                        .font(.title2.weight(.semibold))
                    Text(request.projection.rootFolderPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "person.2.badge.gearshape")
                    .font(.title)
                    .foregroundStyle(.tint)
            }

            HStack(spacing: 12) {
                summaryCard(
                    title: "Ready",
                    value: request.projection.records.count,
                    symbol: "checkmark.circle.fill",
                    color: .green
                )
                summaryCard(
                    title: "Omitted",
                    value: request.projection.omissions.count,
                    symbol: "eye.slash.fill",
                    color: request.projection.omissions.isEmpty ? .secondary : .orange
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Research handoff summary")
            .accessibilityValue(
                SalesResearchAccessibility.handoffSummaryValue(
                    ready: request.projection.records.count,
                    omitted: request.projection.omissions.count
                )
            )
            .accessibilityIdentifier(SalesResearchAccessibility.handoffSummary)

            if request.projection.omissions.isEmpty {
                Label("No sensitive, location-bearing, or unsupported items were excluded.", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                GroupBox("Omissions disclosed in the export") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(request.projection.omissions, id: \.itemID) { omission in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(omission.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(label(for: omission.reasonCode))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 155)
                }
            }

            Picker("Export format", selection: $format) {
                Text("Markdown").tag(HandoffFormat.markdown)
                Text("CSV").tag(HandoffFormat.csv)
                Text("JSON").tag(HandoffFormat.json)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(SalesResearchAccessibility.handoffFormat)
            .accessibilityValue(formatLabel)

            HStack {
                Text("Only this folder and its descendants are included. Vault and History are never exported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier(SalesResearchAccessibility.cancelHandoff)
                Button("Copy Markdown") {
                    copyMarkdown(request.projection)
                }
                .disabled(request.projection.records.isEmpty)
                .accessibilityIdentifier(SalesResearchAccessibility.copyHandoff)
                Button("Export \(formatLabel)…") {
                    export(request.projection, format)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(request.projection.records.isEmpty)
                .accessibilityIdentifier(SalesResearchAccessibility.exportHandoff)
                .accessibilityValue(formatLabel)
            }
        }
        .padding(22)
        .frame(width: 650)
        .frame(minHeight: 470)
        .accessibilityIdentifier(SalesResearchAccessibility.handoffReview)
    }

    private var formatLabel: String {
        switch format {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .json: "JSON"
        }
    }

    private func summaryCard(title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.title2.weight(.bold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func label(for reason: HandoffOmissionReason) -> String {
        switch reason {
        case .sensitive: "Sensitive content"
        case .locationMetadataNotShareable: "Location metadata"
        case .localFileReference: "Local file reference"
        case .unsupportedBinaryAsset: "Image or rich asset"
        case .missingFolder: "Missing folder"
        case .corruptItem: "Unreadable item"
        }
    }
}
