import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSync
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case automations = "Automations"
    case destinations = "App Handoffs"
    case assistant = "AI Assistant"
    case crm = "CRM"
    case sync = "iCloud"
    case license = "License"
    case privacy = "Privacy"

    var id: Self { self }

    static var visibleCases: [Self] {
        allCases.filter { $0 != .automations }
    }

    /// Mac App Store builds never embed direct-license commerce configuration and must not
    /// surface direct-license activation, settings, or purchase language, so the License tab
    /// itself is hidden there. Premium capabilities stay unlocked exactly as the engineering-
    /// evaluation policy already unlocks them; only this tab's visibility differs.
    static func visibleCases(isMacAppStoreDistribution: Bool) -> [Self] {
        visibleCases.filter { $0 != .license || !isMacAppStoreDistribution }
    }

    static func resolved(storedValue: String) -> Self {
        switch storedValue {
        case "Apps", "Open With", "Open in Apps", "AI Handoffs":
            return .destinations
        case "Assistant":
            return .assistant
        case SettingsTab.automations.rawValue:
            return .general
        default:
            return Self(rawValue: storedValue) ?? .general
        }
    }

    static func resolved(storedValue: String, isMacAppStoreDistribution: Bool) -> Self {
        let tab = resolved(storedValue: storedValue)
        if tab == .license, isMacAppStoreDistribution { return .general }
        return tab
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .automations: "bolt"
        case .destinations: "arrow.up.forward.app"
        case .assistant: "sparkles"
        case .crm: "building.2"
        case .sync: "icloud"
        case .license: "checkmark.seal"
        case .privacy: "hand.raised"
        }
    }
}

enum SettingsLayout {
    static let maximumDetailContentWidth: CGFloat = 760
}

enum MenuBarClipLimitAccessibility {
    static let label = "Adjust clips shown"
    static let hint = "Increase or decrease the menu bar clip count from 1 to 1,000."

    static func value(_ count: Int) -> String {
        "\(count) clip\(count == 1 ? "" : "s")"
    }
}

/// An invisible native geometry witness used by the visual acceptance suite. Keeping the probe
/// attached to the bounded detail container means the test measures SwiftUI's real resolved
/// width rather than merely asserting the source constant.
final class SettingsDetailWidthProbeView: NSView {
    override var isFlipped: Bool { true }
}

private struct SettingsDetailWidthProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsDetailWidthProbeView {
        SettingsDetailWidthProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: SettingsDetailWidthProbeView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage private var selectedTabRawValue: String
    private let performsLiveRefreshes: Bool

    init(
        model: AppModel,
        defaults: UserDefaults = .standard,
        performsLiveRefreshes: Bool = true
    ) {
        self.model = model
        self.performsLiveRefreshes = performsLiveRefreshes
        _selectedTabRawValue = AppStorage(
            wrappedValue: SettingsTab.general.rawValue,
            "settings.selectedTab",
            store: defaults
        )
    }

    var body: some View {
        NavigationSplitView {
            List(
                SettingsTab.visibleCases(isMacAppStoreDistribution: model.isMacAppStoreDistribution),
                selection: selectedTabBinding
            ) { tab in
                Label(tab.rawValue, systemImage: tab.symbol)
                    .lineLimit(1)
                    .tag(tab)
                    .accessibilityLabel(tab.rawValue)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 220)
            .accessibilityLabel("Settings sections")
        } detail: {
            Group {
                switch selectedTabBinding.wrappedValue {
                case .general: GeneralSettings(
                    model: model,
                    performsLiveRefreshes: performsLiveRefreshes
                )
                case .automations: AutomationSettings(model: model)
                case .destinations: DestinationSettings(
                    model: model,
                    performsLiveRefreshes: performsLiveRefreshes
                )
                case .assistant: AssistantSettings(model: model)
                case .crm: CRMSettingsView(model: model)
                case .sync: SavedLibrarySyncSettings(model: model)
                case .license: DirectLicenseSettingsView(model: model)
                case .privacy: PrivacySettings(
                    model: model,
                    performsLiveRefreshes: performsLiveRefreshes
                )
                }
            }
            .id(selectedTabBinding.wrappedValue)
            // Keep long settings copy readable on wide windows while allowing the minimum
            // supported window to use every available point. The outer frame centers the
            // bounded form and creates calm margins once the detail column exceeds 760 pt.
            .frame(
                maxWidth: SettingsLayout.maximumDetailContentWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .overlay {
                SettingsDetailWidthProbe()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("uiAcceptance.settings.root")
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            if let status = model.statusMessage {
                StatusToast(message: status) { model.dismissStatus() }
                    .padding(.vertical, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Clipboard Router", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "The action could not be completed.")
        }
        .animation(.snappy, value: model.statusMessage)
    }

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: {
                SettingsTab.resolved(
                    storedValue: selectedTabRawValue,
                    isMacAppStoreDistribution: model.isMacAppStoreDistribution
                )
            },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }
}

enum MenuBarClipLimitDraft {
    static func validValue(in text: String, range: ClosedRange<Int>) -> Int? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              let value = Int(candidate),
              range.contains(value)
        else {
            return nil
        }
        return value
    }

    static func committedValue(
        in text: String,
        currentValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, let value = Int(candidate) else {
            return currentValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct SavedLibrarySyncSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Saved-library sync") {
                Toggle(
                    "Sync saved clips and folders with iCloud",
                    isOn: Binding(
                        get: { model.isSavedLibrarySyncEnabled },
                        set: { model.setSavedLibrarySyncEnabled($0) }
                    )
                )
                .disabled(model.syncContainerIdentifier == nil && !model.isSavedLibrarySyncEnabled)

                Label(
                    "Saved text, rich text, images, and folders are eligible after safety checks. Device-local file references, clipboard history, and Vault never enter sync.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "Receiving remote changes updates the saved library only. It never writes to your Mac clipboard.",
                    systemImage: "clipboard"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("State") {
                    Label(syncStatusText, systemImage: syncStatusSymbol)
                        .foregroundStyle(syncStatusColor)
                }
                if model.syncContainerIdentifier == nil {
                    LabeledContent(
                        "Eligible saved items",
                        value: "\(model.snapshot.savedClips.count + model.snapshot.folders.count)"
                    )
                } else {
                    LabeledContent(
                        "Pending changes",
                        value: "\(model.pendingSavedLibraryEntityCount)"
                    )
                }
                if let date = model.syncLastSuccessfulDate {
                    LabeledContent("Last successful sync") {
                        Text(date, style: .relative)
                    }
                }
                if let container = model.syncContainerIdentifier {
                    LabeledContent("CloudKit container", value: container)
                        .font(.caption)
                } else {
                    LabeledContent("CloudKit container", value: "Not configured")
                }
                LabeledContent("Push refresh", value: cloudPushStatusText)
                LabeledContent(
                    "Attachment recovery",
                    value: assetRecoveryStatusText
                )

                if let message = model.syncAvailabilityMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let message = model.cloudPushRegistrationMessage {
                    Label(message, systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        model.synchronizeSavedLibrary()
                    }
                    .disabled(
                        !model.isSavedLibrarySyncEnabled
                            || model.syncContainerIdentifier == nil
                            || isSyncing
                    )
                }
            }

            if model.hasPendingSyncAccountChange {
                Section("iCloud account changed") {
                    Label(
                        "Sync is paused before upload because macOS reported a different iCloud account.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                    LabeledContent("Previously approved", value: model.approvedSyncAccountLabel)
                    LabeledContent("Newly detected", value: model.pendingSyncAccountLabel)
                    Text("Confirm only if you intend to upload the queued saved clips and folders to the newly detected account. History and Vault are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Keep Sync Paused") {
                            model.keepSyncAccountChangePaused()
                        }
                        Spacer()
                        Button("Confirm New Account and Sync") {
                            model.confirmPendingSyncAccountChange()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if model.syncContainerIdentifier == nil {
                Section("Why sync is unavailable") {
                    Text("CloudKit requires an Apple Developer-signed build. The app's ClipboardRouterCloudKitContainerIdentifier Info.plist value must exactly match its iCloud container entitlement. This local build intentionally does not construct CKContainer, and local clipboard features continue normally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isSyncing: Bool {
        if case .syncing = model.syncSnapshot.status { return true }
        return false
    }

    private var syncStatusText: String {
        if model.hasPendingSyncAccountChange {
            return "Waiting for account confirmation"
        }
        switch model.syncSnapshot.status {
        case .disabled: return "Off"
        case .idle: return "Up to date"
        case .syncing: return "Syncing"
        case .offline: return "Offline — changes queued"
        case let .accountUnavailable(account):
            return "iCloud account unavailable (\(account.rawValue))"
        case .failed: return "Needs attention"
        }
    }

    private var syncStatusSymbol: String {
        if model.hasPendingSyncAccountChange {
            return "person.crop.circle.badge.exclamationmark"
        }
        switch model.syncSnapshot.status {
        case .disabled: return "icloud.slash"
        case .idle: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "wifi.slash"
        case .accountUnavailable, .failed: return "exclamationmark.icloud"
        }
    }

    private var syncStatusColor: Color {
        if model.hasPendingSyncAccountChange { return .orange }
        switch model.syncSnapshot.status {
        case .idle: return Color.green
        case .syncing: return Color.blue
        case .offline, .accountUnavailable, .failed: return Color.orange
        case .disabled: return Color.secondary
        }
    }

    private var cloudPushStatusText: String {
        switch model.cloudPushInstallationStatus {
        case .notConfigured:
            return "Not configured — polling only"
        case .installing:
            return "Verifying subscriptions"
        case let .ready(_, repairedScopes):
            return repairedScopes.isEmpty
                ? "Ready — polling retained as recovery"
                : "Ready — repaired \(repairedScopes.count) subscription(s)"
        case let .unavailable(issue):
            return issue.message
        }
    }

    private var assetRecoveryStatusText: String {
        let states = model.syncSnapshot.entityStates.values
        let active = states.filter {
            switch $0 {
            case .preparingAssets, .uploadingAssets, .downloadingAssets: true
            default: false
            }
        }.count
        let failed = states.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        if active > 0 { return "\(active) item\(active == 1 ? "" : "s") in progress" }
        if failed > 0 { return "Retry available with Sync Now" }
        return "Verified"
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    let performsLiveRefreshes: Bool

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch Clipboard Router at login",
                    isOn: Binding(
                        get: {
                            model.launchAtLoginState == .on
                                || model.launchAtLoginState == .requiresApproval
                        },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(model.launchAtLoginState == .unavailable)

                switch model.launchAtLoginState {
                case .requiresApproval:
                    Label(
                        "macOS requires approval before Clipboard Router can launch at login.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("Open Login Items Settings") {
                        model.openLoginItemsSettings()
                    }
                case .unavailable:
                    Text("Launch at login is unavailable in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .off:
                    Text("Turn this on to start Clipboard Router automatically after you sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .on:
                    Text("Clipboard Router will start automatically after you sign in to your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Capture") {
                Toggle(
                    "Keep clipboard history",
                    isOn: Binding(
                        get: { model.isCaptureEnabled },
                        set: { _ in model.toggleCapture() }
                    )
                )
                Text("Clipboard Router checks for changes every 350 milliseconds. Content present before launch is not imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("macOS clipboard access") {
                LabeledContent("System access", value: model.pasteboardAccessState.title)
                if model.pasteboardAccessState == .denied {
                    Label(
                        "Allow Clipboard Router in System Settings > Privacy & Security, then return here. Capture is not running while access is denied.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if model.pasteboardAccessState == .willAsk {
                    Text("The General pasteboard defaults to asking on first programmatic access. Complete onboarding, then respond to the macOS permission prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.pasteboardAccessState == .asksOnAccess {
                    Text("macOS is configured to ask before programmatic clipboard reads. User-initiated paste actions are treated separately by the system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Clipboard access is available on this version of macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History retention") {
                Picker("Automatically remove history after", selection: retentionBinding) {
                    Text("1 day").tag(RetentionChoice.oneDay)
                    Text("7 days").tag(RetentionChoice.sevenDays)
                    Text("30 days").tag(RetentionChoice.thirtyDays)
                    Text("Never").tag(RetentionChoice.unlimited)
                }
                Text("Saved clips are kept until you delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                MenuBarClipLimitControl(model: model)
                Text("Enter any number from 1 to 1,000. Pinned clips appear first, Recent fills the remaining slots, and the menu remains scrollable. This does not change how much history is stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                Picker(
                    "Show Clipboard Router",
                    selection: Binding(
                        get: { model.globalHotKeyChoice },
                        set: { model.setGlobalHotKeyChoice($0) }
                    )
                ) {
                    ForEach(GlobalHotKeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Picker(
                    "Create Note",
                    selection: Binding(
                        get: { model.createNoteHotKeyChoice },
                        set: { model.setCreateNoteHotKeyChoice($0) }
                    )
                ) {
                    ForEach(GlobalHotKeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Picker(
                    "Quick Paste",
                    selection: Binding(
                        get: { model.insertPaletteHotKeyChoice },
                        set: { model.setInsertPaletteHotKeyChoice($0) }
                    )
                ) {
                    ForEach(GlobalHotKeyChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text("The shortcut uses the macOS hotkey API and does not require Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text Expansion") {
                Toggle(
                    "Expand saved aliases as I type",
                    isOn: Binding(
                        get: { model.isTextExpansionEnabled },
                        set: { model.setTextExpansionEnabled($0) }
                    )
                )
                LabeledContent("System access", value: textExpansionStatusText)
                Text("Type an exact saved alias such as ;followup, then Space, Tab, or Return. Only ordinary saved text, links, and notes are eligible. Sensitive, location-bearing, rich-media, file, Vault, excluded-app, and Private Session content is blocked. Press Escape immediately after an expansion to restore the alias.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isTextExpansionEnabled,
                   model.textExpansionStatus == .permissionRequired
                {
                    Button("Request Accessibility Access") {
                        model.refreshTextExpansionState(promptIfNeeded: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if performsLiveRefreshes {
                model.refreshLaunchAtLoginState()
                model.refreshTextExpansionState()
            }
        }
    }

    private var retentionBinding: Binding<RetentionChoice> {
        Binding(
            get: { RetentionChoice(policy: model.snapshot.settings.retentionPolicy) },
            set: { model.setRetention($0.policy) }
        )
    }

    private var textExpansionStatusText: String {
        switch model.textExpansionStatus {
        case .off: "Off"
        case .permissionRequired: "Accessibility permission required"
        case .ready: "Ready"
        case let .blocked(message): message
        }
    }
}

private enum RetentionChoice: Hashable {
    case oneDay
    case sevenDays
    case thirtyDays
    case unlimited

    init(policy: HistoryRetentionPolicy) {
        switch policy.maximumAge {
        case HistoryRetentionPolicy.oneDay.maximumAge: self = .oneDay
        case HistoryRetentionPolicy.sevenDays.maximumAge: self = .sevenDays
        case HistoryRetentionPolicy.thirtyDays.maximumAge: self = .thirtyDays
        default: self = .unlimited
        }
    }

    var policy: HistoryRetentionPolicy {
        switch self {
        case .oneDay: .oneDay
        case .sevenDays: .sevenDays
        case .thirtyDays: .thirtyDays
        case .unlimited: .unlimited
        }
    }
}

private struct MenuBarClipLimitControl: View {
    @ObservedObject var model: AppModel
    @FocusState private var isTextFieldFocused: Bool
    @State private var draft: String

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: String(model.menuBarClipLimit))
    }

    var body: some View {
        LabeledContent("Clips shown") {
            HStack(spacing: 8) {
                TextField("", text: $draft)
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($isTextFieldFocused)
                    .onSubmit(commitDraft)
                    .accessibilityLabel("Clips shown")
                    .accessibilityHint("Enter a number from 1 to 1,000.")
                    .accessibilityIdentifier("uiAcceptance.settings.menuBarClipLimit")

                Stepper(
                    "",
                    value: Binding(
                        get: { model.menuBarClipLimit },
                        set: { value in
                            model.setMenuBarClipLimit(value)
                            draft = String(model.menuBarClipLimit)
                        }
                    ),
                    in: AppModel.menuBarClipLimitRange
                )
                .labelsHidden()
                .accessibilityLabel(MenuBarClipLimitAccessibility.label)
                .accessibilityValue(MenuBarClipLimitAccessibility.value(model.menuBarClipLimit))
                .accessibilityHint(MenuBarClipLimitAccessibility.hint)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .onChange(of: isTextFieldFocused) { _, isFocused in
            if !isFocused {
                commitDraft()
            }
        }
        .onChange(of: model.menuBarClipLimit) { _, value in
            if !isTextFieldFocused {
                draft = String(value)
            }
        }
        .onDisappear(perform: commitDraft)
    }

    private func commitDraft() {
        let committed = MenuBarClipLimitDraft.committedValue(
            in: draft,
            currentValue: model.menuBarClipLimit,
            range: AppModel.menuBarClipLimitRange
        )
        model.setMenuBarClipLimit(committed)
        draft = String(model.menuBarClipLimit)
    }
}

private struct DestinationSettings: View {
    @ObservedObject var model: AppModel
    let performsLiveRefreshes: Bool

    var body: some View {
        Form {
            Section {
                Text("This controls only the preferred AI keyboard shortcut. Copy & Open uses a separate all-app browser each time.")
                    .foregroundStyle(.secondary)
                Button("Refresh Installed Apps", systemImage: "arrow.clockwise") {
                    model.refreshApplicationExclusionOptions(force: true)
                }
                .disabled(model.isDiscoveringApplications)
            }

            Section("Preferred AI shortcut") {
                Picker("AI app", selection: $model.preferredDestinationID) {
                    ForEach(DestinationRegistry.all) { destination in
                        Text(destination.displayName).tag(destination.id)
                    }
                }
            }

            ForEach(DestinationRegistry.all) { destination in
                DestinationApplicationPicker(model: model, destination: destination)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if performsLiveRefreshes {
                model.refreshApplicationExclusionOptions(force: false)
            }
        }
    }
}

private struct AssistantSettings: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    @State private var isTestingConnection = false
    @State private var connectionResult: String?

    var body: some View {
        Form {
            Section("On-device") {
                LabeledContent("Apple Intelligence", value: onDeviceStatus)
                Text("When available, on-device requests stay on this Mac and expose no tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cloud") {
                LabeledContent(
                    "Connection",
                    value: model.isHostedAssistantConfigured ? "API key in Keychain" : "Not configured"
                )
                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                HStack {
                    Button("Save to Keychain") {
                        if model.saveHostedAssistantCredential(apiKey) {
                            apiKey = ""
                            connectionResult = nil
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.isHostedAssistantConfigured {
                        Button(isTestingConnection ? "Testing…" : "Test Connection") {
                            isTestingConnection = true
                            connectionResult = nil
                            Task {
                                connectionResult = await model.testHostedAssistantConnection()
                                isTestingConnection = false
                            }
                        }
                        .disabled(isTestingConnection || !model.isHostedAssistantModelValid)
                        Button("Disconnect", role: .destructive) {
                            model.removeHostedAssistantCredential()
                            connectionResult = nil
                        }
                    }
                }

                if let connectionResult {
                    Label(connectionResult, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                TextField("Model", text: $model.hostedAssistantModel)
                    .textFieldStyle(.roundedBorder)
                if !model.isHostedAssistantModelValid {
                    Label("Enter a model name, or restore the low-cost default.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Use gpt-5-nano") { model.restoreDefaultHostedAssistantModel() }
                }
                Text("The default is gpt-5-nano for low-cost quick queries, enrichment, rewriting, and formatting. Research web is enabled only when you explicitly choose that task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Allow reviewed Cloud Assistant requests",
                    isOn: $model.isHostedAssistantConsentGranted
                )
                .disabled(!model.isHostedAssistantConfigured)
                if !model.isHostedAssistantConfigured {
                    Text("Save an API key to enable reviewed Cloud requests. Test Connection verifies the current key and model before you use them on a clip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Each request still requires pressing Send. The selected clip, local conversation, and prompt are sent to OpenAI. Vault, Private Session, sensitive, secret, location-bearing, file, and rich-media clips are blocked. Clipboard Router requests store=false, but your API account and provider data controls still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Safety") {
                Label("AI output is always an unverified draft.", systemImage: "doc.badge.ellipsis")
                Label("Assistant cannot open apps, send messages, update Contacts, or write to a CRM.", systemImage: "hand.raised")
                Label("Links and citations open only after you click them.", systemImage: "link.badge.plus")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.hostedAssistantModel) { _, _ in connectionResult = nil }
        .onChange(of: apiKey) { _, _ in connectionResult = nil }
    }

    private var onDeviceStatus: String {
        switch model.onDeviceAIAvailability {
        case .available: "Ready"
        case .requiresMacOS26: "Requires macOS 26"
        case .appleIntelligenceUnavailable: "Unavailable"
        }
    }
}

private struct DestinationApplicationPicker: View {
    @ObservedObject var model: AppModel
    let destination: ExternalDestination

    private var installedURLs: [URL] {
        model.installedApplicationURLs(for: destination)
    }

    var body: some View {
        Section(destination.displayName) {
            if installedURLs.isEmpty, model.isDiscoveringDestinationApplications {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking installed apps…")
                        .foregroundStyle(.secondary)
                }
            } else if installedURLs.isEmpty {
                Label("App not installed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                if let fallback = destination.webFallbackURL {
                    Text("The browser fallback is \(fallback.host() ?? fallback.absoluteString).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(destination.displayName) is installed-app-only. No web destination will be opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if installedURLs.count == 1 {
                LabeledContent("Recognized product", value: destination.displayName)
                Text(installedURLs[0].path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Picker(
                    "Exact application",
                    selection: Binding(
                        get: { model.selectedApplicationURL(for: destination) },
                        set: { model.selectApplicationURL($0, for: destination) }
                    )
                ) {
                    Text("Choose an app…").tag(URL?.none)
                    ForEach(installedURLs, id: \.path) { url in
                        Text(url.path).tag(URL?.some(url))
                    }
                }
                Text("Multiple apps use the same bundle identifier. Clipboard Router will not guess which one you intended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Choose Application…", systemImage: "folder") {
                model.chooseApplication(for: destination)
            }
            Text("The selected app is verified as the requested product before it is remembered. Clipboard Router still only copies and opens; it never submits content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var model: AppModel
    let performsLiveRefreshes: Bool
    @State private var newBundleIdentifier = ""
    @State private var confirmsHistoryClear = false
    @State private var applicationSearch = ""
    @State private var showsAdvancedBundleID = false

    var body: some View {
        Form {
            Section("Currently excluded") {
                if excludedBundleIdentifiers.isEmpty {
                    Label("No applications are excluded.", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedBundleIdentifiers, id: \.self) { bundleIdentifier in
                        HStack(spacing: 9) {
                            if let application = discoveredApplication(
                                forBundleIdentifier: bundleIdentifier
                            ) {
                                Image(nsImage: NSWorkspace.shared.icon(
                                    forFile: application.applicationURL.path
                                ))
                                .resizable()
                                .frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(application.displayName)
                                    Text(bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: "app.badge.checkmark")
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.secondary)
                                Text(bundleIdentifier)
                            }

                            Spacer()
                            Button("Allow Again") {
                                model.excludeApplication(
                                    bundleIdentifier: bundleIdentifier,
                                    excluded: false
                                )
                            }
                            .accessibilityLabel("Allow \(bundleIdentifier) again")
                        }
                    }
                }

                Text("This list is stored independently of app discovery, so exclusions remain visible and removable even when an app is uninstalled or outside a scanned folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded applications") {
                Text("Clipboard changes made while an excluded app is frontmost are ignored before they reach your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search installed and running apps", text: $applicationSearch)
                    .textFieldStyle(.roundedBorder)

                if model.isDiscoveringApplications {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.applicationExclusionOptions.isEmpty
                            ? "Checking verified applications…"
                            : "Updating verified applications…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Checking verified applications")
                }

                ForEach(filteredApplications.prefix(30)) { application in
                    Toggle(
                        isOn: Binding(
                            get: {
                                model.snapshot.settings.capturePolicy
                                    .excludedApplicationBundleIdentifiers
                                    .contains(application.bundleIdentifier.lowercased())
                            },
                            set: {
                                model.excludeApplication(
                                    bundleIdentifier: application.bundleIdentifier,
                                    excluded: $0
                                )
                            }
                        )
                    ) {
                        HStack(spacing: 9) {
                            Image(nsImage: NSWorkspace.shared.icon(
                                forFile: application.applicationURL.path
                            ))
                            .resizable()
                            .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(application.displayName)
                                Text(application.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if application.isRunning {
                                Text("Running")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Button("Choose Application…", systemImage: "folder") {
                    model.chooseExcludedApplication()
                }

                Button("Refresh Installed Apps", systemImage: "arrow.clockwise") {
                    model.refreshApplicationExclusionOptions(force: true)
                }
                .disabled(model.isDiscoveringApplications)

                DisclosureGroup("Advanced bundle identifier", isExpanded: $showsAdvancedBundleID) {
                    HStack {
                        TextField("com.company.private-app", text: $newBundleIdentifier)
                        Button("Exclude") {
                            let identifier = newBundleIdentifier.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            guard !identifier.isEmpty else { return }
                            model.excludeApplication(
                                bundleIdentifier: identifier,
                                excluded: true
                            )
                            newBundleIdentifier = ""
                        }
                        .disabled(newBundleIdentifier.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                    }
                }
            }

            Section("Clipboard history") {
                Button("Clear History…", role: .destructive) { confirmsHistoryClear = true }
                Text("This removes ordinary history only. Saved clips are not removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CaptureContextSettingsSections(model: model)

            Section("Secure Paste") {
                Picker(
                    "Clear unchanged Vault content after",
                    selection: Binding(
                        get: { model.securePasteTimeoutSeconds },
                        set: { model.setSecurePasteTimeout(seconds: $0) }
                    )
                ) {
                    ForEach([15, 30, 45, 60], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                Text("Clipboard Router clears only the Vault value it copied. A newer copy is never removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local-first") {
                Label("Clipboard content is stored locally unless you explicitly enable a separate sync feature.", systemImage: "internaldrive")
                Label("External app handoff only copies and opens. Optional Cloud Assistant credentials stay in this Mac's Keychain and are never synced.", systemImage: "hand.raised")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if performsLiveRefreshes {
                model.refreshApplicationExclusionOptions(force: false)
                model.refreshCaptureContextStatus()
            }
        }
        .confirmationDialog(
            "Clear all ordinary clipboard history?",
            isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved clips will stay in their folders.")
        }
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let query = applicationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.applicationExclusionOptions }
        return model.applicationExclusionOptions.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var excludedBundleIdentifiers: [String] {
        model.snapshot.settings.capturePolicy.excludedApplicationBundleIdentifiers.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func discoveredApplication(
        forBundleIdentifier bundleIdentifier: String
    ) -> ApplicationExclusionOption? {
        model.applicationExclusionOptions.first {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }
}
