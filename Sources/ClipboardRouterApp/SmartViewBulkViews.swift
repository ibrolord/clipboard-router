import AppKit
import ClipboardRouterCore
import SwiftUI

struct BulkLibraryActionResult: Identifiable, Equatable {
    struct Failure: Identifiable, Equatable {
        let id: UUID
        let title: String
        let reason: String
    }

    let id = UUID()
    let action: String
    let successCount: Int
    let failures: [Failure]
}

struct SaveSmartViewSheet: View {
    @ObservedObject var model: AppModel
    let editing: UserSmartView?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var query: String
    @State private var isPinned: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    init(model: AppModel, editing: UserSmartView? = nil) {
        self.model = model
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _query = State(initialValue: editing?.query ?? model.searchText)
        _isPinned = State(initialValue: editing?.isPinned ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "Save Smart View" : "Edit Smart View")
                .font(.title2.weight(.semibold))
            Text("Smart Views save only this query definition on this Mac. Results and clip content are never copied into the definition.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("uiAcceptance.smartViews.name")
                TextField("Query", text: $query, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("uiAcceptance.smartViews.query")
                Toggle("Pin near the top of Smart Views", isOn: $isPinned)
                    .accessibilityIdentifier("uiAcceptance.smartViews.pinned")
            }
            if let explanation = try? ClipSearchQuery.validate(query), !explanation.explanations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active filters").font(.caption.weight(.semibold))
                    Text(explanation.explanations.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("uiAcceptance.smartViews.validation")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("uiAcceptance.smartViews.cancel")
                Button(editing == nil ? "Save" : "Update") {
                    isSaving = true
                    saveError = nil
                    Task { @MainActor in
                        let succeeded: Bool
                        if let editing {
                            succeeded = await model.updateUserSmartView(
                                id: editing.id,
                                name: name,
                                query: query,
                                pinned: isPinned
                            )
                        } else {
                            succeeded = await model.createUserSmartView(
                                name: name,
                                query: query,
                                pinned: isPinned
                            )
                        }
                        isSaving = false
                        if succeeded {
                            dismiss()
                        } else {
                            saveError = model.errorMessage ?? "The Smart View could not be saved."
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || validationError != nil)
                .accessibilityIdentifier("uiAcceptance.smartViews.commit")
            }
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uiAcceptance.smartViews.editor")
        .accessibilityValue(SmartViewBulkAccessibility.editorValue(
            editingID: editing?.id,
            isPinned: isPinned,
            isSaving: isSaving,
            validationError: validationError,
            saveError: saveError
        ))
    }

    private var validationError: String? {
        do {
            _ = try UserSmartView.validateName(name)
            _ = try ClipSearchQuery.validate(query)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct BulkTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    let apply: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Tags").font(.title2.weight(.semibold))
            Text("Tags are added to eligible Saved clips and notes. History remains unchanged.")
                .foregroundStyle(.secondary)
            TextField("Comma-separated tags", text: $tags)
                .accessibilityIdentifier("uiAcceptance.bulk.tagField")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("uiAcceptance.bulk.tagCancel")
                Button("Add Tags") {
                    apply(tags.split(separator: ",").map(String.init))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("uiAcceptance.bulk.tagCommit")
            }
        }
        .padding(24)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uiAcceptance.bulk.tagSheet")
        .accessibilityValue("tags=\(SmartViewBulkAccessibility.component(tags))")
    }
}

struct BulkMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [FolderDestination]
    let apply: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Eligible Saved Items").font(.title2.weight(.semibold))
            Text("History, sensitive items, and read-only shared items will be left unchanged and listed in the result.")
                .foregroundStyle(.secondary)
            List {
                Button("Saved (no folder)") { apply(nil); dismiss() }
                    .accessibilityIdentifier(SmartViewBulkAccessibility.bulkDestination(nil))
                    .accessibilityValue("eligible=true|path=Saved")
                ForEach(folders) { folder in
                    Button(folder.path) { apply(folder.id); dismiss() }
                        .disabled(!folder.canAcceptItems)
                        .accessibilityHint(folder.canAcceptItems ? "Move selected items" : "You do not have permission to edit this folder")
                        .accessibilityIdentifier(SmartViewBulkAccessibility.bulkDestination(folder.id))
                        .accessibilityValue(
                            "eligible=\(folder.canAcceptItems)|path=\(SmartViewBulkAccessibility.component(folder.path))"
                        )
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .accessibilityIdentifier(SmartViewBulkAccessibility.bulkMoveCancel)
            }
        }
        .padding(24)
        .frame(width: 480, height: 390)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SmartViewBulkAccessibility.bulkMoveSheet)
        .accessibilityValue("destinations=\(folders.count + 1)")
    }
}

struct BulkLibraryResultSheet: View {
    let result: BulkLibraryActionResult
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.action).font(.title2.weight(.semibold))
            Label("\(result.successCount) item\(result.successCount == 1 ? "" : "s") completed", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            if !result.failures.isEmpty {
                Text("Not changed").font(.headline)
                List(result.failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(failure.title).lineLimit(1)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("uiAcceptance.bulk.failure.\(failure.id.uuidString.lowercased())")
                    .accessibilityValue("title=\(SmartViewBulkAccessibility.component(failure.title))|reason=\(SmartViewBulkAccessibility.component(failure.reason))")
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("uiAcceptance.bulk.resultDone")
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: result.failures.isEmpty ? 180 : 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uiAcceptance.bulk.result")
        .accessibilityValue(SmartViewBulkAccessibility.bulkResultValue(result))
    }
}

enum SmartViewBulkAccessibility {
    static let bulkSave = "uiAcceptance.bulk.save"
    static let bulkMove = "uiAcceptance.bulk.move"
    static let bulkPin = "uiAcceptance.bulk.pin"
    static let bulkUnpin = "uiAcceptance.bulk.unpin"
    static let bulkExport = "uiAcceptance.bulk.export"
    static let bulkClear = "uiAcceptance.bulk.clear"
    static let bulkMoveSheet = "uiAcceptance.bulk.moveSheet"
    static let bulkMoveCancel = "uiAcceptance.bulk.moveCancel"

    static func smartViewRow(_ id: UUID) -> String {
        "uiAcceptance.smartViews.row.\(uuid(id))"
    }

    static func smartViewControl(_ control: String, id: UUID) -> String {
        "uiAcceptance.smartViews.\(control).\(uuid(id))"
    }

    static func smartViewValue(_ view: UserSmartView, order: Int) -> String {
        "name=\(component(view.name))|query=\(component(view.query))|pinned=\(view.isPinned)|order=\(order)"
    }

    static func editorValue(
        editingID: UUID?,
        isPinned: Bool,
        isSaving: Bool,
        validationError: String?,
        saveError: String?
    ) -> String {
        "mode=\(editingID == nil ? "create" : "edit")|view=\(editingID.map(uuid) ?? "none")|pinned=\(isPinned)|saving=\(isSaving)|valid=\(validationError == nil)|error=\(component(saveError ?? validationError ?? "none"))"
    }

    static func bulkResultValue(_ result: BulkLibraryActionResult) -> String {
        "action=\(component(result.action))|success=\(result.successCount)|failure=\(result.failures.count)"
    }

    static func bulkDestination(_ folderID: UUID?) -> String {
        "uiAcceptance.bulk.destination.\(folderID.map(uuid) ?? "saved")"
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
