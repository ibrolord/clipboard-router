import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case off
    case on
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginServicing {
    var state: LaunchAtLoginState { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .off
        case .enabled:
            return .on
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
