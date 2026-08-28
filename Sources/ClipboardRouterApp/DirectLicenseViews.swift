import ClipboardRouterCore
import SwiftUI

struct DirectLicenseStatusView: View {
    let status: DirectLicenseStatus
    let isEngineeringBuild: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if isEngineeringBuild { return "Engineering Build" }
        return switch status {
        case let .active(plan, _): "\(plan.label) active"
        case .grace: "Offline grace"
        case .expired: "License expired"
        case .revoked: "License revoked"
        case .unavailable(.noLicense): "No license connected"
        case .unavailable(.serviceUnavailable): "Service unavailable"
        case .unavailable(.verifierUnavailable): "Verification unavailable"
        case .unavailable(.engineeringBuild): "Engineering Build"
        case .tampered: "License needs attention"
        }
    }

    private var detail: String {
        if isEngineeringBuild {
            return "Features are unlocked only for local engineering evaluation. No real purchase, trial, subscription, service domain, or signing key is configured."
        }
        return switch status {
        case let .active(_, expiresAt?):
            "Verified on this Mac through \(expiresAt.formatted(date: .abbreviated, time: .omitted))."
        case .active(_, nil):
            "Verified for this account and Mac with no subscription expiry."
        case let .grace(_, endsAt):
            "Premium features remain available offline through \(endsAt.formatted(date: .abbreviated, time: .omitted))."
        case .expired:
            "New premium creation, automations, cloud, and AI are paused. Existing clips remain searchable, copyable, exportable, and deletable."
        case .revoked:
            "This device entitlement was revoked. Existing clips remain available."
        case .unavailable(.noLicense):
            "Start a trial, activate a key, or restore an account. Existing clips are never locked."
        case .unavailable(.serviceUnavailable):
            "The service could not be reached. Stored license evidence was not replaced or deleted."
        case .unavailable(.verifierUnavailable):
            "This build cannot verify signed license tokens."
        case .unavailable(.engineeringBuild):
            "No commerce configuration is present."
        case .tampered:
            "The signed token, device scope, secure clock state, or system clock could not be trusted. Existing clips remain available."
        }
    }

    private var symbol: String {
        if isEngineeringBuild { return "hammer.fill" }
        return switch status {
        case .active: "checkmark.seal.fill"
        case .grace: "clock.badge.checkmark"
        case .expired: "calendar.badge.exclamationmark"
        case .revoked: "xmark.shield.fill"
        case .unavailable: "questionmark.circle"
        case .tampered: "exclamationmark.shield.fill"
        }
    }

    private var color: Color {
        if isEngineeringBuild { return .orange }
        return switch status {
        case .active: Color.green
        case .grace: Color.orange
        case .expired, .revoked, .tampered: Color.red
        case .unavailable: Color.secondary
        }
    }
}

struct DirectLicenseSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var licenseKey = ""
    @State private var restoreAccount = ""
    @State private var confirmsDisconnect = false
    @State private var confirmsDeactivate = false

    var body: some View {
        Form {
            Section("License") {
                DirectLicenseStatusView(
                    status: model.directLicenseStatus,
                    isEngineeringBuild: model.isDirectLicenseEngineeringBuild
                )
                LabeledContent("Device", value: model.directLicenseDeviceDescription)
                if let account = model.directLicenseAccountID {
                    LabeledContent("Account", value: masked(account))
                }
                if let licenseID = model.directLicenseID {
                    LabeledContent("License", value: masked(licenseID))
                }
            }

            if model.isDirectLicenseCommerceConfigured {
                Section("Connect a license") {
                    Button("Start Trial") { model.startDirectLicenseTrial() }

                    SecureField("License key", text: $licenseKey)
                    Button("Activate License") {
                        let value = licenseKey
                        licenseKey = ""
                        model.activateDirectLicense(key: value)
                    }
                    .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    TextField("Account ID for restore", text: $restoreAccount)
                    Button("Restore License") {
                        let value = restoreAccount
                        restoreAccount = ""
                        model.restoreDirectLicense(accountID: value)
                    }
                    .disabled(restoreAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.isDirectLicenseOperationInProgress {
                        HStack { ProgressView().controlSize(.small); Text("Verifying…") }
                            .foregroundStyle(.secondary)
                    }
                }

                Section("This device") {
                    Button("Refresh License") { model.refreshDirectLicense() }
                    Button("Disconnect from this Mac…", role: .destructive) {
                        confirmsDisconnect = true
                    }
                    Button("Deactivate this Mac…", role: .destructive) {
                        confirmsDeactivate = true
                    }
                    Text("Disconnect removes only this Mac's non-synchronizing Keychain token. Deactivate first confirms removal with the configured licensing service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Distribution configuration required") {
                    Label("Bundled P-256 public key", systemImage: "key.horizontal")
                    Label("HTTPS licensing service domain", systemImage: "network")
                    Label("Real commerce provider and product mapping", systemImage: "creditcard")
                    Text("Activation and restore controls remain unavailable until all three are real and configured. This app does not claim that an engineering build was purchased.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Your data stays yours") {
                Label("Search, copy, export, and delete always remain available.", systemImage: "lock.open")
                Text("Expiry, revocation, or verification failure gates only new premium creation, automations, cloud features, and AI. License tokens stay in this Mac's non-synchronizing Keychain and are never shown or logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isDirectLicenseOperationInProgress)
        .confirmationDialog(
            "Disconnect this Mac?",
            isPresented: $confirmsDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { model.disconnectDirectLicense() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing clips remain available. This does not release a server-side device seat.")
        }
        .confirmationDialog(
            "Deactivate this Mac?",
            isPresented: $confirmsDeactivate,
            titleVisibility: .visible
        ) {
            Button("Deactivate", role: .destructive) { model.deactivateDirectLicenseDevice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The local license is removed only after the configured service confirms deactivation.")
        }
    }

    private func masked(_ value: String) -> String {
        value.count <= 8 ? "••••" : "…\(value.suffix(8))"
    }
}

struct DirectLicenseOnboardingStatusView: View {
    let isEngineeringBuild: Bool

    var body: some View {
        if isEngineeringBuild {
            Label(
                "Engineering Build — premium features are unlocked for evaluation, not purchased.",
                systemImage: "hammer.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.1), in: Capsule())
        }
    }
}

private extension DirectLicensePlan {
    var label: String {
        return switch self {
        case .trial: "Trial"
        case .lifetime: "Lifetime"
        case .subscription: "Subscription"
        }
    }
}
