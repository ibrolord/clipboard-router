import Foundation
import Security

public struct VaultCapabilityReport: Equatable, Sendable {
    public let isAvailable: Bool
    public let message: String?

    public init(isAvailable: Bool, message: String? = nil) {
        self.isAvailable = isAvailable
        self.message = message
    }
}

public enum VaultCapabilityChecker {
    /// Data Protection Keychain use must be backed by a signed application identifier. This check
    /// prevents ad-hoc packages from presenting a raw `errSecMissingEntitlement` dialog.
    public static func currentProcess() -> VaultCapabilityReport {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return unavailable()
        }
        let applicationIdentifier = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.application-identifier" as CFString,
            nil
        ) as? String
        let teamIdentifier = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.team-identifier" as CFString,
            nil
        ) as? String
        guard applicationIdentifier?.isEmpty == false,
              teamIdentifier?.isEmpty == false
        else {
            return unavailable()
        }
        return VaultCapabilityReport(isAvailable: true)
    }

    private static func unavailable() -> VaultCapabilityReport {
        VaultCapabilityReport(
            isAvailable: false,
            message: "Vault requires an Apple Developer-signed build. Clipboard history remains local and fully usable in this build."
        )
    }
}
