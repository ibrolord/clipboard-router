import AppKit
import ClipboardRouterCore
import SwiftUI

enum CRMAcceptanceAccessibility {
    static let settings = "uiAcceptance.crm.settings"
    static let setupProvider = "uiAcceptance.crm.setup.provider"
    static let setupName = "uiAcceptance.crm.setup.name"
    static let setupClientID = "uiAcceptance.crm.setup.clientID"
    static let setupBrokerURL = "uiAcceptance.crm.setup.brokerURL"
    static let setupSave = "uiAcceptance.crm.setup.save"

    static func connection(_ id: UUID) -> String { "uiAcceptance.crm.connection.\(uuid(id))" }
    static func connect(_ id: UUID) -> String { "uiAcceptance.crm.connect.\(uuid(id))" }
    static func disconnect(_ id: UUID) -> String { "uiAcceptance.crm.disconnect.\(uuid(id))" }
    static func remove(_ id: UUID) -> String { "uiAcceptance.crm.remove.\(uuid(id))" }
    static func review(_ id: UUID) -> String { "uiAcceptance.crm.review.\(uuid(id))" }
    static func close(_ id: UUID) -> String { "uiAcceptance.crm.close.\(uuid(id))" }
    static func cancel(_ id: UUID) -> String { "uiAcceptance.crm.cancel.\(uuid(id))" }
    static func confirm(_ id: UUID) -> String { "uiAcceptance.crm.confirm.\(uuid(id))" }
    static func receipt(_ id: UUID) -> String { "uiAcceptance.crm.receipt.\(uuid(id))" }
    static func reconcile(_ id: UUID) -> String { "uiAcceptance.crm.reconcile.\(uuid(id))" }

    static func connectionValue(_ state: CRMConnectionState) -> String {
        switch state {
        case let .setupRequired(message):
            "state=setupRequired|account=none|scopes=0|reason=\(component(message))"
        case .disconnected:
            "state=disconnected|account=none|scopes=0|reason=none"
        case let .connected(accountID, scopes):
            "state=connected|account=\(component(accountID ?? "none"))|scopes=\(scopes.count)|reason=none"
        }
    }

    static func reviewValue(_ draft: CRMReviewDraft, valid: Bool, inFlight: Bool) -> String {
        "provider=\(draft.provider.rawValue)|object=\(draft.object.rawValue)|mode=\(draft.mode.rawValue)|fields=\(draft.fields.values.lazy.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)|valid=\(valid)|inFlight=\(inFlight)"
    }

    static func receiptValue(_ outcome: CRMWriteOutcome) -> String {
        switch outcome {
        case let .succeeded(id, link):
            "status=succeeded|providerID=\(component(id))|link=\(component(link?.absoluteString ?? "none"))"
        case let .duplicate(id, link):
            "status=duplicate|providerID=\(component(id))|link=\(component(link?.absoluteString ?? "none"))"
        case let .rateLimited(date):
            "status=rateLimited|retry=\(component(date.map { ISO8601DateFormatter().string(from: $0) } ?? "none"))"
        case let .reconciliationRequired(key):
            "status=reconciliationRequired|key=\(component(key))"
        case .reconnectRequired:
            "status=reconnectRequired"
        case let .failed(message):
            "status=failed|message=\(component(message))"
        }
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

enum CRMConnectionState: Equatable, Sendable {
    case setupRequired(String)
    case disconnected
    case connected(accountID: String?, scopes: Set<String>)

    var label: String {
        switch self {
        case .setupRequired: "Setup required"
        case .disconnected: "Not connected"
        case .connected: "Connected"
        }
    }
}

struct CRMReviewDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceClipID: UUID
    let sourceFingerprint: String
    var connectionID: UUID
    var provider: CRMProvider
    var object: CRMObjectType
    var mode: CRMWriteMode
    var existingProviderID: String
    var fields: [String: String]

    func makeReview() throws -> CRMWriteReview {
        try CRMWriteReview(
            id: id,
            connectionID: connectionID,
            provider: provider,
            object: object,
            mode: mode,
            existingProviderID: mode == .update ? existingProviderID : nil,
            mapping: CRMFieldMapping(
                object: object,
                fields: fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ),
            sourceFingerprint: sourceFingerprint
        )
    }
}

struct CRMSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var provider: CRMProvider = .salesforce
    @State private var displayName = "Salesforce"
    @State private var clientID = ""
    @State private var brokerURL = ""

    var body: some View {
        Form {
            Section("Connections") {
                if model.crmConnectionDefinitions.isEmpty {
                    ContentUnavailableView(
                        "No CRM connected",
                        systemImage: "building.2.crop.circle",
                        description: Text("Add Salesforce or HubSpot. Clipboard content is sent only after an editable review and explicit Create or Update confirmation.")
                    )
                }
                ForEach(model.crmConnectionDefinitions) { definition in
                    connectionRow(definition)
                }
            }

            Section("Add connection") {
                Picker("Provider", selection: $provider) {
                    Text("Salesforce").tag(CRMProvider.salesforce)
                    Text("HubSpot").tag(CRMProvider.hubSpot)
                }
                .accessibilityIdentifier(CRMAcceptanceAccessibility.setupProvider)
                .accessibilityValue("provider=\(provider.rawValue)")
                .onChange(of: provider) { _, value in
                    displayName = value == .salesforce ? "Salesforce" : "HubSpot"
                }
                TextField("Connection name", text: $displayName)
                    .accessibilityIdentifier(CRMAcceptanceAccessibility.setupName)
                TextField("OAuth client ID", text: $clientID)
                    .textContentType(.username)
                    .accessibilityIdentifier(CRMAcceptanceAccessibility.setupClientID)
                if provider == .hubSpot {
                    TextField("HTTPS token broker URL", text: $brokerURL)
                        .accessibilityIdentifier(CRMAcceptanceAccessibility.setupBrokerURL)
                    Text("HubSpot's token exchange requires a client secret. Clipboard Router never embeds it; connection stays blocked until you configure your HTTPS broker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Configure this callback in your Salesforce External Client App: clipboardrouter://oauth/salesforce. Enable authorization code with PKCE and the api and refresh_token scopes without requiring a client secret for refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Save Connection", systemImage: "plus") {
                        let redirect = URL(string: "clipboardrouter://oauth/\(provider == .salesforce ? "salesforce" : "hubspot")")!
                        model.saveCRMConnection(CRMConnectionDefinition(
                            provider: provider,
                            displayName: displayName,
                            clientID: clientID,
                            redirectURI: redirect,
                            tokenBrokerURL: provider == .hubSpot ? URL(string: brokerURL) : nil
                        ))
                        clientID = ""
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(CRMAcceptanceAccessibility.setupSave)
                    .accessibilityValue(
                        "enabled=\(!displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"
                    )
                }
            }

            Section("Write boundary") {
                Label("Contacts and Companies are checked for duplicates before Create.", systemImage: "person.2.badge.gearshape")
                Label("Only the allowlisted fields visible in the review are sent.", systemImage: "checkmark.shield")
                Label("Vault, sensitive, secret, location-bearing, file, image, rich-text, and Private Session items are blocked.", systemImage: "lock.shield")
                Text("OAuth tokens are stored in this Mac's non-synchronizing Keychain. Disconnect removes credentials but keeps the connection definition so it can be reconnected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCRMConnectionStates() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CRMAcceptanceAccessibility.settings)
        .accessibilityValue("connections=\(model.crmConnectionDefinitions.count)|provider=\(provider.rawValue)")
    }

    @ViewBuilder
    private func connectionRow(_ definition: CRMConnectionDefinition) -> some View {
        let state = model.crmConnectionStates[definition.id] ?? .disconnected
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(definition.displayName, systemImage: definition.provider == .hubSpot ? "h.square" : "cloud")
                    .font(.headline)
                Spacer()
                Text(state.label).foregroundStyle(stateColor(state))
            }
            if case let .setupRequired(message) = state {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if case let .connected(accountID, scopes) = state {
                if let accountID { LabeledContent("Account", value: accountID).font(.caption) }
                if !scopes.isEmpty { LabeledContent("Scopes", value: scopes.sorted().joined(separator: ", ")).font(.caption) }
            }
            HStack {
                if case .connected = state {
                    Button("Disconnect") { model.disconnectCRMConnection(definition.id) }
                        .accessibilityIdentifier(CRMAcceptanceAccessibility.disconnect(definition.id))
                } else {
                    Button("Connect…") { model.beginCRMConnection(definition.id) }
                        .disabled(definition.externalSetupBlocker != nil)
                        .accessibilityIdentifier(CRMAcceptanceAccessibility.connect(definition.id))
                        .accessibilityValue("enabled=\(definition.externalSetupBlocker == nil)")
                }
                Button("Remove Definition", role: .destructive) {
                    model.removeCRMConnectionDefinition(definition.id)
                }
                .accessibilityIdentifier(CRMAcceptanceAccessibility.remove(definition.id))
                Spacer()
                Text(definition.redirectURI.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CRMAcceptanceAccessibility.connection(definition.id))
        .accessibilityValue(CRMAcceptanceAccessibility.connectionValue(state))
    }

    private func stateColor(_ state: CRMConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .setupRequired: .orange
        case .disconnected: .secondary
        }
    }
}

struct CRMWriteReviewSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CRMReviewDraft

    init(model: AppModel, draft: CRMReviewDraft) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review CRM write").font(.title2.bold())
                    Text("Nothing is sent until you confirm below.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.dismissCRMReview(); dismiss() }
                    .accessibilityIdentifier(CRMAcceptanceAccessibility.close(draft.id))
            }
            .padding(20)
            Divider()

            Form {
                Section("Destination") {
                    Picker("Connection", selection: $draft.connectionID) {
                        ForEach(model.crmConnectionDefinitions) { definition in
                            Text(definition.displayName).tag(definition.id)
                        }
                    }
                    .onChange(of: draft.connectionID) { _, value in
                        if let definition = model.crmConnectionDefinitions.first(where: { $0.id == value }) {
                            draft.provider = definition.provider
                        }
                    }
                    Picker("Object", selection: $draft.object) {
                        Text("Contact").tag(CRMObjectType.contact)
                        Text("Company").tag(CRMObjectType.company)
                        Text("Follow-up Task").tag(CRMObjectType.task)
                    }
                    .onChange(of: draft.object) { _, value in
                        draft.fields = model.defaultCRMFields(for: value, clipID: draft.sourceClipID)
                    }
                    Picker("Operation", selection: $draft.mode) {
                        Text("Create new").tag(CRMWriteMode.create)
                        Text("Update existing").tag(CRMWriteMode.update)
                    }
                    if draft.mode == .update {
                        TextField("Provider record ID", text: $draft.existingProviderID)
                    }
                }

                Section("Reviewed fields") {
                    ForEach(CRMFieldMapping.allowedFields[draft.object]!.sorted(), id: \.self) { field in
                        TextField(fieldLabel(field), text: Binding(
                            get: { draft.fields[field] ?? "" },
                            set: { draft.fields[field] = $0 }
                        ), axis: field == "body" ? .vertical : .horizontal)
                        .lineLimit(field == "body" ? 3...8 : 1...1)
                    }
                    Text("Blank fields are omitted. No hidden clip metadata, location, or tokens are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if draft.mode == .create, draft.object == .contact {
                        Text(draft.provider == .salesforce
                            ? "Salesforce requires a last name. Duplicate checking also requires an email or phone."
                            : "Duplicate checking requires an email or phone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.mode == .create, draft.object == .company {
                        Text(draft.provider == .hubSpot
                            ? "HubSpot duplicate checking requires a domain."
                            : "Salesforce duplicate checking requires a company name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let outcome = model.crmWriteOutcome {
                    Section("Receipt") { receipt(outcome) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.isCRMWriteInFlight { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.dismissCRMReview(); dismiss() }
                    .accessibilityIdentifier(CRMAcceptanceAccessibility.cancel(draft.id))
                Button(draft.mode == .create ? "Create in CRM" : "Update in CRM") {
                    model.confirmCRMWrite(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCRMWriteInFlight || !isValid)
                .accessibilityIdentifier(CRMAcceptanceAccessibility.confirm(draft.id))
                .accessibilityValue("enabled=\(!model.isCRMWriteInFlight && isValid)")
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 590)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CRMAcceptanceAccessibility.review(draft.id))
        .accessibilityValue(CRMAcceptanceAccessibility.reviewValue(
            draft,
            valid: isValid,
            inFlight: model.isCRMWriteInFlight
        ))
    }

    private var isValid: Bool {
        (try? draft.makeReview()) != nil
            && (draft.mode == .create || !draft.existingProviderID.isEmpty)
            && (model.crmConnectionStates[draft.connectionID].map {
                if case .connected = $0 { return true }
                return false
            } ?? false)
    }

    @ViewBuilder
    private func receipt(_ outcome: CRMWriteOutcome) -> some View {
        Group {
            switch outcome {
            case let .succeeded(id, link):
                Label("Write succeeded. Provider ID: \(id)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let link { Link("Open CRM record", destination: link) }
            case let .duplicate(id, link):
                Label("A matching record already exists. Nothing was created. ID: \(id)", systemImage: "person.crop.circle.badge.checkmark")
                if let link { Link("Open existing record", destination: link) }
            case let .rateLimited(date):
                Label(date.map { "Provider asked to retry after \($0.formatted())." } ?? "Provider rate limited this write.", systemImage: "clock")
                    .foregroundStyle(.orange)
            case let .reconciliationRequired(key):
                VStack(alignment: .leading) {
                    Label("The connection timed out after the write may have reached the provider. It was not retried.", systemImage: "questionmark.diamond")
                        .foregroundStyle(.orange)
                    Text("Reconciliation key: \(key)").font(.caption2.monospaced()).textSelection(.enabled)
                    Button("Check for matching record") { model.reconcileCRMWrite(draft) }
                        .disabled(draft.object == .task || model.isCRMWriteInFlight)
                        .accessibilityIdentifier(CRMAcceptanceAccessibility.reconcile(draft.id))
                        .accessibilityValue(
                            "enabled=\(draft.object != .task && !model.isCRMWriteInFlight)"
                        )
                }
            case .reconnectRequired:
                Label("Reconnect this CRM account in Settings before writing.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CRMAcceptanceAccessibility.receipt(draft.id))
        .accessibilityValue(CRMAcceptanceAccessibility.receiptValue(outcome))
    }

    private func fieldLabel(_ field: String) -> String {
        field.reduce(into: "") { result, character in
            if character.isUppercase { result.append(" ") }
            result.append(character)
        }.capitalized
    }
}
