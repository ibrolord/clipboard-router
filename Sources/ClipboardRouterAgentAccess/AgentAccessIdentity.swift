// Derives both peers' code-identity policies from validated, signed state only. There is no
// argument, environment variable or file that can widen who may connect.

import Darwin
import Foundation
import Security

public enum AgentAccessIdentityError: Error, Equatable, Sendable {
    case selfSigningUnavailable(OSStatus)
    case unsignedOrAdHoc
    case unexpectedIdentifier
    case notHardened
    case forbiddenEntitlement
    case notInsideAppBundle
    case appBundleSignatureInvalid(OSStatus)
    case appBundleInfoUnavailable
    case distributionChannelNotDirect
    case appNotSandboxed
    case containerHomeMismatch
    case invalidIdentifierCharacters
    case endpointPathTooLong

    public var reasonCode: String {
        switch self {
        case let .selfSigningUnavailable(status): "self_signing_unavailable_\(status)"
        case .unsignedOrAdHoc: "unsigned_or_ad_hoc_build"
        case .unexpectedIdentifier: "unexpected_signing_identifier"
        case .notHardened: "hardened_runtime_missing"
        case .forbiddenEntitlement: "forbidden_entitlement"
        case .notInsideAppBundle: "helper_not_inside_app_bundle"
        case let .appBundleSignatureInvalid(status): "app_bundle_signature_invalid_\(status)"
        case .appBundleInfoUnavailable: "app_bundle_info_unavailable"
        case .distributionChannelNotDirect: "distribution_channel_not_direct"
        case .appNotSandboxed: "app_not_sandboxed"
        case .containerHomeMismatch: "container_home_mismatch"
        case .invalidIdentifierCharacters: "invalid_identifier_characters"
        case .endpointPathTooLong: "endpoint_path_too_long"
        }
    }
}

public enum AgentAccessConstants {
    /// Explicit code-signing identifier given to `Contents/Helpers/cr` by direct packaging.
    public static let bridgeIdentifier = "com.clipboardrouter.cr"
    public static let helperRelativePath = "Contents/Helpers/cr"
    public static let channelInfoKey = "ClipboardRouterDistributionChannel"
    /// The raw signed marker must equal this exactly. Missing, unknown and Mac App Store
    /// values all deny; this deliberately does not reuse the lenient channel provider.
    public static let requiredChannel = "direct"
    public static let endpointDirectoryName = "m"
    public static let endpointSocketName = "s"
    static let sandboxEntitlement = "com.apple.security.app-sandbox"
}

/// The private endpoint inside the app's sandbox container: `<container>/Data/m/s`.
public struct AgentAccessEndpoint: Sendable, Equatable {
    public let directoryPath: String
    public let socketPath: String

    public init(containerDataPath: String) throws {
        let root = URL(fileURLWithPath: containerDataPath, isDirectory: true).standardizedFileURL.path
        directoryPath = root + "/" + AgentAccessConstants.endpointDirectoryName
        socketPath = directoryPath + "/" + AgentAccessConstants.endpointSocketName
        guard socketPath.utf8.count <= LocalSocket.maxPathBytes else {
            throw AgentAccessIdentityError.endpointPathTooLong
        }
    }

    /// Path computed by the unsandboxed bridge from the account's home directory (not $HOME).
    public static func forBridge(appBundleIdentifier: String, userHome: String) throws -> AgentAccessEndpoint {
        guard AgentAccessIdentity.isSafeIdentifier(appBundleIdentifier) else {
            throw AgentAccessIdentityError.invalidIdentifierCharacters
        }
        return try AgentAccessEndpoint(
            containerDataPath: userHome + "/Library/Containers/" + appBundleIdentifier + "/Data"
        )
    }

    /// Longest home-directory path the endpoint can support for a given bundle identifier.
    public static func maxHomePathBytes(appBundleIdentifier: String) -> Int {
        let suffix = "/Library/Containers/\(appBundleIdentifier)/Data/"
            + "\(AgentAccessConstants.endpointDirectoryName)/\(AgentAccessConstants.endpointSocketName)"
        return LocalSocket.maxPathBytes - suffix.utf8.count
    }

    public static func accountHomeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }
}

public struct SigningSnapshot: Sendable, Equatable {
    public var identifier: String
    public var teamIdentifier: String?
    public var executablePath: String
    public var isHardened: Bool
    public var entitlementKeysSetTrue: [String]
    public var hasForbiddenEntitlement: Bool
    public var isSandboxed: Bool
    /// False when the dynamic signing information carried no entitlements dictionary at all.
    public var entitlementsDictPresent: Bool = true
}

public enum AgentAccessIdentity {
    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 155
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
            }
    }

    static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// Requirement text built only from validated identifiers.
    public static func teamRequirement(team: String, identifier: String) throws -> String {
        guard isTeamIdentifier(team) else { throw AgentAccessIdentityError.unsignedOrAdHoc }
        guard isSafeIdentifier(identifier) else { throw AgentAccessIdentityError.invalidIdentifierCharacters }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    /// Reads the running process's own signature (dynamic, validated by the kernel).
    public static func selfSigning() throws -> SigningSnapshot {
        var code: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &code)
        guard status == errSecSuccess, let code else { throw AgentAccessIdentityError.selfSigningUnavailable(status) }
        status = SecCodeCheckValidity(code, SecCSFlags(), nil)
        guard status == errSecSuccess else { throw AgentAccessIdentityError.selfSigningUnavailable(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self), CodeIdentityVerifier.infoFlags, &information
        )
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw AgentAccessIdentityError.selfSigningUnavailable(status)
        }
        var url: CFURL?
        status = SecCodeCopyPath(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(), &url)
        guard status == errSecSuccess, let path = (url as URL?)?.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw AgentAccessIdentityError.selfSigningUnavailable(status)
        }
        return snapshot(info: info, executablePath: path)
    }

    static func snapshot(info: [String: Any], executablePath: String) -> SigningSnapshot {
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let forbidden = (try? CodeIdentityVerifier.check(
            entitlements: entitlements,
            policy: CodeIdentityPolicy(requirement: "")
        )) == nil
        return SigningSnapshot(
            identifier: info[kSecCodeInfoIdentifier as String] as? String ?? "",
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            executablePath: executablePath,
            isHardened: flags & CodeIdentityVerifier.flagRuntime != 0,
            entitlementKeysSetTrue: entitlements.compactMap { ($0.value as? Bool) == true ? $0.key : nil }.sorted(),
            hasForbiddenEntitlement: forbidden,
            isSandboxed: (entitlements[AgentAccessConstants.sandboxEntitlement] as? Bool) == true,
            entitlementsDictPresent: info[kSecCodeInfoEntitlementsDict as String] is [String: Any]
        )
    }
}

/// Everything the bridge needs, derived from its own signature and its containing bundle.
public struct BridgeIdentityContext: Sendable, Equatable {
    public var appBundlePath: String
    public var appBundleIdentifier: String
    public var teamIdentifier: String
    public var serverPolicy: CodeIdentityPolicy
    public var endpoint: AgentAccessEndpoint

    /// Production resolution for `cr mcp`. A copied helper has no containing bundle and is
    /// refused; a symlink resolves to the in-bundle helper because the kernel records the
    /// real path. Mac App Store helpers (sandbox + inherit) and unsigned builds are refused.
    public static func resolve() throws -> BridgeIdentityContext {
        let me = try AgentAccessIdentity.selfSigning()
        guard let home = AgentAccessEndpoint.accountHomeDirectory() else {
            throw AgentAccessIdentityError.appBundleInfoUnavailable
        }
        return try resolve(selfSigning: me, userHome: home)
    }

    static func resolve(selfSigning me: SigningSnapshot, userHome: String) throws -> BridgeIdentityContext {
        guard let team = me.teamIdentifier, AgentAccessIdentity.isTeamIdentifier(team) else {
            throw AgentAccessIdentityError.unsignedOrAdHoc
        }
        guard me.identifier == AgentAccessConstants.bridgeIdentifier else {
            throw AgentAccessIdentityError.unexpectedIdentifier
        }
        guard me.isHardened else { throw AgentAccessIdentityError.notHardened }
        guard !me.hasForbiddenEntitlement, !me.isSandboxed else {
            throw AgentAccessIdentityError.forbiddenEntitlement
        }
        let helperSuffix = "/" + AgentAccessConstants.helperRelativePath
        guard me.executablePath.hasSuffix(helperSuffix) else { throw AgentAccessIdentityError.notInsideAppBundle }
        let bundlePath = String(me.executablePath.dropLast(helperSuffix.count))
        guard bundlePath.hasSuffix(".app") else { throw AgentAccessIdentityError.notInsideAppBundle }

        let bundleInfo = try validatedAppBundle(path: bundlePath, team: team)
        guard bundleInfo.channel == AgentAccessConstants.requiredChannel else {
            throw AgentAccessIdentityError.distributionChannelNotDirect
        }
        let requirement = try AgentAccessIdentity.teamRequirement(team: team, identifier: bundleInfo.bundleIdentifier)
        return BridgeIdentityContext(
            appBundlePath: bundlePath,
            appBundleIdentifier: bundleInfo.bundleIdentifier,
            teamIdentifier: team,
            serverPolicy: CodeIdentityPolicy(
                requirement: requirement,
                expectedCodePaths: [bundlePath, bundleInfo.mainExecutablePath],
                requiredTrueEntitlements: [AgentAccessConstants.sandboxEntitlement]
            ),
            endpoint: try AgentAccessEndpoint.forBridge(
                appBundleIdentifier: bundleInfo.bundleIdentifier,
                userHome: userHome
            )
        )
    }

    struct AppBundleInfo {
        var bundleIdentifier: String
        var channel: String?
        var mainExecutablePath: String
    }

    /// Static validation of the whole containing bundle (including nested code) against our
    /// own team. Only after it passes are its sealed Info.plist values trusted.
    static func validatedAppBundle(path: String, team: String) throws -> AppBundleInfo {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else { throw AgentAccessIdentityError.appBundleSignatureInvalid(status) }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        status = SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else { throw AgentAccessIdentityError.appBundleSignatureInvalid(status) }
        // kSecCSCheckNestedCode | kSecCSStrictValidate
        let flags = SecCSFlags(rawValue: (1 << 3) | (1 << 4))
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else { throw AgentAccessIdentityError.appBundleSignatureInvalid(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, CodeIdentityVerifier.infoFlags, &information)
        guard status == errSecSuccess, let info = information as? [String: Any],
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let signedIdentifier = info[kSecCodeInfoIdentifier as String] as? String,
              signedIdentifier == bundleIdentifier,
              AgentAccessIdentity.isSafeIdentifier(bundleIdentifier),
              let mainExecutable = (info[kSecCodeInfoMainExecutable as String] as? URL)
        else { throw AgentAccessIdentityError.appBundleInfoUnavailable }
        return AppBundleInfo(
            bundleIdentifier: bundleIdentifier,
            channel: plist[AgentAccessConstants.channelInfoKey] as? String,
            mainExecutablePath: mainExecutable.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }
}

/// Everything the sandboxed app needs to accept only its own in-bundle helper.
public struct AppIdentityContext: Sendable, Equatable {
    public var clientPolicy: CodeIdentityPolicy
    public var endpoint: AgentAccessEndpoint
    public var teamIdentifier: String

    public static func resolve(bundle: Bundle = .main) throws -> AppIdentityContext {
        try resolve(
            selfSigning: AgentAccessIdentity.selfSigning(),
            bundleIdentifier: bundle.bundleIdentifier,
            rawChannel: bundle.object(forInfoDictionaryKey: AgentAccessConstants.channelInfoKey) as? String,
            bundlePath: bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
            containerDataPath: NSHomeDirectory(),
            accountHome: AgentAccessEndpoint.accountHomeDirectory()
        )
    }

    /// Content-free explanation of `resolve(bundle:)`: fixed keys, `1`/`0` flags and reason codes
    /// only. No path, user name or identifier value is ever included. For UI-acceptance runs.
    public static func diagnose(bundle: Bundle = .main) -> [String: String] {
        let snapshot = try? AgentAccessIdentity.selfSigning()
        let executable = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path
        let result: String
        do {
            _ = try resolve(bundle: bundle)
            result = "ok"
        } catch {
            result = (error as? AgentAccessIdentityError)?.reasonCode ?? "unexpected"
        }
        return diagnostics(
            selfSigning: snapshot,
            bundleIdentifier: bundle.bundleIdentifier,
            rawChannel: bundle.object(forInfoDictionaryKey: AgentAccessConstants.channelInfoKey) as? String,
            bundleExecutablePath: executable,
            containerDataPath: NSHomeDirectory(),
            resolveResult: result
        )
    }

    static func diagnostics(
        selfSigning me: SigningSnapshot?,
        bundleIdentifier: String?,
        rawChannel: String?,
        bundleExecutablePath: String?,
        containerDataPath: String,
        resolveResult: String
    ) -> [String: String] {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        let suffix = bundleIdentifier.map { "/Library/Containers/\($0)/Data" }
        let canonical = URL(fileURLWithPath: containerDataPath).resolvingSymlinksInPath().standardizedFileURL.path
        let standardized = URL(fileURLWithPath: containerDataPath).standardizedFileURL.path
        return [
            "selfSigningAvailable": flag(me != nil),
            "isSandboxedEntitlement": flag(me?.isSandboxed ?? false),
            "entitlementsDictPresent": flag(me?.entitlementsDictPresent ?? false),
            "hasTeam": flag(me?.teamIdentifier.map(AgentAccessIdentity.isTeamIdentifier) ?? false),
            "identifierMatchesBundle": flag(me != nil && me?.identifier == bundleIdentifier),
            "isHardened": flag(me?.isHardened ?? false),
            "rawChannelIsDirect": flag(rawChannel == AgentAccessConstants.requiredChannel),
            "homeHasExpectedSuffix": flag(suffix.map(containerDataPath.hasSuffix) ?? false),
            "homeHasExpectedSuffixIgnoringCase": flag(
                suffix.map { standardized.lowercased().hasSuffix($0.lowercased()) } ?? false
            ),
            "homeIsExpectedDirectoryObject": flag(
                bundleIdentifier.map {
                    isContainerDataPath(containerDataPath, bundleIdentifier: $0, accountHome: AgentAccessEndpoint.accountHomeDirectory())
                } ?? false
            ),
            "homeIsStandardized": flag(containerDataPath == standardized),
            "homeEndsInSlash": flag(containerDataPath.hasSuffix("/")),
            "canonicalHomeHasExpectedSuffix": flag(suffix.map(canonical.hasSuffix) ?? false),
            "executablePathEqualsBundleExecutable": flag(
                me != nil && bundleExecutablePath != nil && me?.executablePath == bundleExecutablePath
            ),
            "resolve": resolveResult,
        ]
    }

    /// True when `path` (the app's sandbox home) is this bundle's container `Data` directory.
    /// An exact `<…>/Library/Containers/<bundle id>/Data` suffix passes. A spelling that differs
    /// only in letter case (the container directory keeps the case it was first created with)
    /// passes only if the filesystem itself resolves both `path` and the path the bridge will
    /// use, `<account home>/Library/Containers/<bundle id>/Data`, to the same directory object
    /// (device + inode, no symlinks). On a case-sensitive volume, or for a different object,
    /// it fails closed. Strings are never treated as equal merely because they fold equally.
    static func isContainerDataPath(
        _ path: String,
        bundleIdentifier: String,
        accountHome: String?,
        sameDirectory: (String, String) -> Bool = AppIdentityContext.isSameDirectoryObject
    ) -> Bool {
        guard AgentAccessIdentity.isSafeIdentifier(bundleIdentifier) else { return false }
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let suffix = "/Library/Containers/\(bundleIdentifier)/Data"
        guard standardized.count > suffix.count else { return false }
        if standardized.hasSuffix(suffix) { return true }
        guard let accountHome, standardized.lowercased().hasSuffix(suffix.lowercased()) else { return false }
        let expected = URL(fileURLWithPath: accountHome, isDirectory: true).standardizedFileURL.path + suffix
        return sameDirectory(standardized, expected)
    }

    /// Both paths exist, neither is a symlink, both are directories, same device and inode.
    static func isSameDirectoryObject(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat()
        var right = stat()
        guard lstat(lhs, &left) == 0, lstat(rhs, &right) == 0,
              (left.st_mode & S_IFMT) == S_IFDIR, (right.st_mode & S_IFMT) == S_IFDIR
        else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func resolve(
        selfSigning me: SigningSnapshot,
        bundleIdentifier: String?,
        rawChannel: String?,
        bundlePath: String,
        containerDataPath: String,
        accountHome: String? = nil,
        sameDirectory: (String, String) -> Bool = AppIdentityContext.isSameDirectoryObject
    ) throws -> AppIdentityContext {
        guard rawChannel == AgentAccessConstants.requiredChannel else {
            throw AgentAccessIdentityError.distributionChannelNotDirect
        }
        guard let team = me.teamIdentifier, AgentAccessIdentity.isTeamIdentifier(team) else {
            throw AgentAccessIdentityError.unsignedOrAdHoc
        }
        guard let bundleIdentifier, me.identifier == bundleIdentifier else {
            throw AgentAccessIdentityError.unexpectedIdentifier
        }
        guard me.isHardened else { throw AgentAccessIdentityError.notHardened }
        // The endpoint is only private when NSHomeDirectory() is the sandbox container.
        guard me.isSandboxed else { throw AgentAccessIdentityError.appNotSandboxed }
        guard Self.isContainerDataPath(
            containerDataPath,
            bundleIdentifier: bundleIdentifier,
            accountHome: accountHome,
            sameDirectory: sameDirectory
        ) else {
            throw AgentAccessIdentityError.containerHomeMismatch
        }
        return AppIdentityContext(
            clientPolicy: CodeIdentityPolicy(
                requirement: try AgentAccessIdentity.teamRequirement(
                    team: team,
                    identifier: AgentAccessConstants.bridgeIdentifier
                ),
                expectedCodePaths: [bundlePath + "/" + AgentAccessConstants.helperRelativePath]
            ),
            endpoint: try AgentAccessEndpoint(containerDataPath: containerDataPath),
            teamIdentifier: team
        )
    }
}
