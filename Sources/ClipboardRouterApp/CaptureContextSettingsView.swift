import AppKit
import ClipboardRouterPlatform
import SwiftUI

struct CaptureContextSettingsSections: View {
    @ObservedObject var model: AppModel
    @State private var deletionTarget: DeletionTarget?

    private enum DeletionTarget: String, Identifiable {
        case device
        case location
        case both

        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: "Delete device context from existing clips?"
            case .location: "Delete location context from existing clips?"
            case .both: "Delete all optional context from existing clips?"
            }
        }
    }

    var body: some View {
        Section("Device context") {
            Toggle(
                "Attach device context to new clips",
                isOn: Binding(
                    get: { model.snapshot.settings.effectiveDeviceContextEnabled },
                    set: { model.setDeviceContextEnabled($0) }
                )
            )
            Text("Off by default. Adds this Mac's label, macOS version, and a stable app-installation ID. Find these clips with device: in Library search.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.snapshot.settings.effectiveDeviceContextEnabled {
                LabeledContent("Device", value: model.captureDeviceContext.label)
                LabeledContent("System", value: model.captureDeviceContext.operatingSystem)
                LabeledContent("Identifier", value: model.captureContextInstallationIDDescription)
            }

            Button("Delete device context from existing clips…", role: .destructive) {
                deletionTarget = .device
            }
        }

        Section("Approximate location") {
            Toggle(
                "Attach an approximate area to new clips",
                isOn: Binding(
                    get: { model.snapshot.settings.effectiveLocationContextEnabled },
                    set: { model.setLocationContextEnabled($0) }
                )
            )
            Text("Enabling this switch does not request permission. Clipboard Router asks macOS only when you choose Allow Location below, then reduces the reading locally to a maximum-five-character geohash. Exact coordinates are not sent to a geocoder or stored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.snapshot.settings.effectiveLocationContextEnabled {
                LabeledContent("Permission", value: authorizationLabel)

                if let location = model.currentCoarseLocation {
                    LabeledContent("Current", value: location.label)
                    if let observedAt = model.coarseLocationObservedAt {
                        LabeledContent("Updated") {
                            Text(observedAt, format: .dateTime.month().day().hour().minute())
                        }
                    }
                }

                HStack {
                    switch model.captureLocationAuthorization {
                    case .notDetermined:
                        Button("Allow Location…") {
                            model.requestCaptureLocationPermissionAndRefresh()
                        }
                    case .authorized:
                        Button("Refresh Location") { model.refreshCaptureLocation() }
                    case .denied, .restricted, .servicesDisabled:
                        Button("Open Location Settings") {
                            if let url = URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    if model.isRefreshingCaptureLocation {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    Button("Disable and Clear") {
                        model.setLocationContextEnabled(false)
                    }
                }
            }

            Label("Located clips remain Local Only and cannot use hosted AI.", systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Future location sharing", value: "Off")

            Button("Delete location context from existing clips…", role: .destructive) {
                deletionTarget = .location
            }
            Button("Delete all optional context from existing clips…", role: .destructive) {
                deletionTarget = .both
            }
        }
        .confirmationDialog(
            deletionTarget?.title ?? "Delete optional context?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletionTarget {
                Button("Delete Context", role: .destructive) {
                    model.deleteCapturedContext(
                        device: deletionTarget == .device || deletionTarget == .both,
                        location: deletionTarget == .location || deletionTarget == .both
                    )
                    self.deletionTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("This updates ordinary History and Saved items. Source application, source URL, and source domain metadata remain unchanged.")
        }
    }

    private var authorizationLabel: String {
        switch model.captureLocationAuthorization {
        case .notDetermined: "Not requested"
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .servicesDisabled: "Location Services off"
        }
    }
}
