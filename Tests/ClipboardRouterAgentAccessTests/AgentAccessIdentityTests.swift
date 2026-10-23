import Foundation
import XCTest
@testable import ClipboardRouterAgentAccess

final class AgentAccessIdentityTests: XCTestCase {
    func snapshot(
        identifier: String = AgentAccessConstants.bridgeIdentifier,
        team: String? = "ABCDE12345",
        path: String = "/Applications/Clipboard Router.app/Contents/Helpers/cr",
        hardened: Bool = true,
        forbidden: Bool = false,
        sandboxed: Bool = false
    ) -> SigningSnapshot {
        SigningSnapshot(
            identifier: identifier,
            teamIdentifier: team,
            executablePath: path,
            isHardened: hardened,
            entitlementKeysSetTrue: [],
            hasForbiddenEntitlement: forbidden,
            isSandboxed: sandboxed
        )
    }

    func bridgeError(_ me: SigningSnapshot) -> AgentAccessIdentityError? {
        do {
            _ = try BridgeIdentityContext.resolve(selfSigning: me, userHome: "/Users/synthetic")
            return nil
        } catch {
            return error as? AgentAccessIdentityError
        }
    }

    func testBridgeRefusesUnsignedWrongIdentifierCopiedAndMacAppStoreHelpers() {
        XCTAssertEqual(bridgeError(snapshot(team: nil)), .unsignedOrAdHoc)
        XCTAssertEqual(bridgeError(snapshot(identifier: "cr")), .unexpectedIdentifier)
        XCTAssertEqual(bridgeError(snapshot(hardened: false)), .notHardened)
        // Mac App Store helper: sandbox + inherit.
        XCTAssertEqual(bridgeError(snapshot(forbidden: true, sandboxed: true)), .forbiddenEntitlement)
        // install-cr.sh style copy: no containing bundle.
        XCTAssertEqual(bridgeError(snapshot(path: "/usr/local/bin/cr")), .notInsideAppBundle)
        XCTAssertEqual(bridgeError(snapshot(path: "/tmp/NotABundle/Contents/Helpers/cr")), .notInsideAppBundle)
    }

    func testBridgeRefusesBundleThatFailsStaticValidation() {
        // A path that is shaped correctly but is not a validly signed bundle of our team.
        let error = bridgeError(snapshot(path: "/tmp/cr-nonexistent-\(UUID().uuidString).app/Contents/Helpers/cr"))
        guard case .appBundleSignatureInvalid = error else {
            return XCTFail("expected static validation failure, got \(String(describing: error))")
        }
    }

    func appError(channel: String?, sandboxed: Bool = true, team: String? = "ABCDE12345", container: String? = nil) -> AgentAccessIdentityError? {
        let bundleID = "com.clipboardrouter.ClipboardRouter"
        do {
            _ = try AppIdentityContext.resolve(
                selfSigning: snapshot(identifier: bundleID, team: team, path: "/Applications/X.app", sandboxed: sandboxed),
                bundleIdentifier: bundleID,
                rawChannel: channel,
                bundlePath: "/Applications/X.app",
                containerDataPath: container ?? "/Users/synthetic/Library/Containers/\(bundleID)/Data"
            )
            return nil
        } catch {
            return error as? AgentAccessIdentityError
        }
    }

    func testAppRequiresExactDirectMarkerTeamAndSandbox() throws {
        XCTAssertEqual(appError(channel: nil), .distributionChannelNotDirect, "missing marker denies")
        XCTAssertEqual(appError(channel: "macAppStore"), .distributionChannelNotDirect)
        XCTAssertEqual(appError(channel: "Direct"), .distributionChannelNotDirect)
        XCTAssertEqual(appError(channel: "unknown"), .distributionChannelNotDirect)
        XCTAssertEqual(appError(channel: "direct", team: nil), .unsignedOrAdHoc)
        XCTAssertEqual(appError(channel: "direct", sandboxed: false), .appNotSandboxed)
        XCTAssertEqual(appError(channel: "direct", container: "/Users/synthetic"), .containerHomeMismatch)
        XCTAssertEqual(AgentAccessIdentityError.containerHomeMismatch.reasonCode, "container_home_mismatch")
        XCTAssertEqual(
            appError(channel: "direct", sandboxed: false, container: "/Users/synthetic"), .appNotSandboxed,
            "the entitlement guard is reported first and stays distinct from the path guard"
        )
        XCTAssertNil(appError(channel: "direct"))

        let context = try AppIdentityContext.resolve(
            selfSigning: snapshot(identifier: "com.clipboardrouter.ClipboardRouter", path: "/Applications/X.app", sandboxed: true),
            bundleIdentifier: "com.clipboardrouter.ClipboardRouter",
            rawChannel: "direct",
            bundlePath: "/Applications/X.app",
            containerDataPath: "/Users/synthetic/Library/Containers/com.clipboardrouter.ClipboardRouter/Data"
        )
        XCTAssertEqual(
            context.clientPolicy.requirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"com.clipboardrouter.cr\""
        )
        XCTAssertEqual(context.clientPolicy.expectedCodePaths, ["/Applications/X.app/Contents/Helpers/cr"])
        XCTAssertTrue(context.clientPolicy.forbiddenEntitlements.contains("com.apple.security.inherit"))
    }

    func testContainerHomeCheckRequiresExactSpellingOrSameDirectoryObject() {
        let id = "com.clipboardrouter.ClipboardRouter.uiacceptance"
        let prefix = "/Users/synthetic/Library/Containers/"
        let alias = prefix + "com.clipboardrouter.ClipboardRouter.UIAcceptance/Data"
        // Exact spelling (with standardization only) passes without consulting the filesystem.
        let neverCalled: (String, String) -> Bool = { _, _ in XCTFail("filesystem consulted for exact match"); return false }
        XCTAssertTrue(AppIdentityContext.isContainerDataPath(prefix + id + "/Data/", bundleIdentifier: id, accountHome: "/Users/synthetic", sameDirectory: neverCalled))
        XCTAssertTrue(AppIdentityContext.isContainerDataPath(prefix + "x/../" + id + "/Data", bundleIdentifier: id, accountHome: nil, sameDirectory: neverCalled))
        // A case alias passes only when the filesystem says both name the same object.
        var compared: [(String, String)] = []
        XCTAssertTrue(AppIdentityContext.isContainerDataPath(alias, bundleIdentifier: id, accountHome: "/Users/synthetic") { compared.append(($0, $1)); return true })
        XCTAssertEqual(compared.first?.1, prefix + id + "/Data", "compared with the path the bridge will use")
        XCTAssertFalse(AppIdentityContext.isContainerDataPath(alias, bundleIdentifier: id, accountHome: "/Users/synthetic") { _, _ in false },
                       "case-sensitive volume or different object fails closed")
        XCTAssertFalse(AppIdentityContext.isContainerDataPath(alias, bundleIdentifier: id, accountHome: nil) { _, _ in true },
                       "unknown account home fails closed")
        XCTAssertEqual(
            appError(channel: "direct", container: prefix + id + "/Data"), .containerHomeMismatch,
            "a different app's container is not this app's container"
        )
        // Everything structurally different still fails closed.
        for bad in [
            "/Users/synthetic",
            prefix + id,
            prefix + id + "/Data/extra",
            prefix + id + ".evil/Data",
            prefix + "x" + id + "/Data",
            prefix + "com.other.app/Data",
            "/Users/synthetic/" + id + "/Data",
            prefix + id + "/Data2",
            "/Library/Containers/" + id + "/Data",
        ] {
            XCTAssertFalse(AppIdentityContext.isContainerDataPath(bad, bundleIdentifier: id, accountHome: "/Users/synthetic") { _, _ in true }, bad)
        }
        XCTAssertFalse(AppIdentityContext.isContainerDataPath(prefix + "a b/Data", bundleIdentifier: "a b", accountHome: "/Users/synthetic") { _, _ in true })
    }

    /// Real directories: identity is decided by device+inode, never by string folding.
    func testSameDirectoryObjectUsesFilesystemIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cr-identity-\(UUID().uuidString)").path
        let real = root + "/Library/Containers/com.Example.CaseApp/Data"
        let other = root + "/Library/Containers/com.example.otherapp/Data"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(AppIdentityContext.isSameDirectoryObject(real, real))
        XCTAssertFalse(AppIdentityContext.isSameDirectoryObject(real, other), "different objects")
        XCTAssertFalse(AppIdentityContext.isSameDirectoryObject(real, root + "/missing"))
        let symlink = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: real)
        XCTAssertFalse(AppIdentityContext.isSameDirectoryObject(symlink, real), "symlinks are not accepted")
        // A case alias of the real directory: accepted only if this volume resolves it to the same inode.
        let folded = root + "/Library/Containers/com.example.caseapp/Data"
        var info = stat()
        let volumeFoldsCase = lstat(folded, &info) == 0
        XCTAssertEqual(
            AppIdentityContext.isContainerDataPath(real, bundleIdentifier: "com.example.caseapp", accountHome: root),
            volumeFoldsCase,
            "alias accepted exactly when the filesystem resolves both names to one directory"
        )
        XCTAssertFalse(AppIdentityContext.isContainerDataPath(other, bundleIdentifier: "com.Example.CaseApp", accountHome: root))
    }

    func testDiagnosticsAreContentFreeFixedKeyFlags() {
        let id = "com.clipboardrouter.ClipboardRouter.uiacceptance"
        let me = snapshot(identifier: id, path: "/Applications/Secret Name.app/Contents/MacOS/X", sandboxed: true)
        let result = AppIdentityContext.diagnostics(
            selfSigning: me,
            bundleIdentifier: id,
            rawChannel: "direct",
            bundleExecutablePath: "/Applications/Secret Name.app/Contents/MacOS/X",
            containerDataPath: "/Users/secretuser/Library/Containers/com.clipboardrouter.ClipboardRouter.UIAcceptance/Data",
            resolveResult: "container_home_mismatch"
        )
        XCTAssertEqual(result["isSandboxedEntitlement"], "1")
        XCTAssertEqual(result["homeHasExpectedSuffix"], "0")
        XCTAssertEqual(result["homeHasExpectedSuffixIgnoringCase"], "1")
        XCTAssertEqual(result["homeIsStandardized"], "1")
        XCTAssertEqual(result["homeEndsInSlash"], "0")
        XCTAssertEqual(result["executablePathEqualsBundleExecutable"], "1")
        XCTAssertEqual(result["identifierMatchesBundle"], "1")
        XCTAssertEqual(result["resolve"], "container_home_mismatch")
        let text = result.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        for secret in ["secretuser", "Secret Name", "ABCDE12345", "Users", "/"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let absent = AppIdentityContext.diagnostics(
            selfSigning: nil, bundleIdentifier: nil, rawChannel: nil, bundleExecutablePath: nil,
            containerDataPath: "/x/", resolveResult: "self_signing_unavailable_1"
        )
        XCTAssertEqual(absent["selfSigningAvailable"], "0")
        XCTAssertEqual(absent["homeEndsInSlash"], "1")
        XCTAssertEqual(absent["identifierMatchesBundle"], "0")
    }

    func testRequirementBuilderRejectsInjection() {
        XCTAssertThrowsError(try AgentAccessIdentity.teamRequirement(team: "ABCDE12345", identifier: "x\" or true or \""))
        XCTAssertThrowsError(try AgentAccessIdentity.teamRequirement(team: "abc", identifier: "com.x"))
    }

    func testEntitlementPolicy() {
        let policy = CodeIdentityPolicy(requirement: "", requiredTrueEntitlements: ["com.apple.security.app-sandbox"])
        XCTAssertThrowsError(try CodeIdentityVerifier.check(entitlements: [:], policy: policy)) {
            XCTAssertEqual($0 as? LocalIPCError, .peerEntitlementMissing("com.apple.security.app-sandbox"))
        }
        XCTAssertThrowsError(try CodeIdentityVerifier.check(
            entitlements: ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true], policy: policy
        ))
        XCTAssertThrowsError(try CodeIdentityVerifier.check(
            entitlements: ["com.apple.security.app-sandbox": true, "com.apple.security.get-task-allow": 1], policy: policy
        ))
        XCTAssertNoThrow(try CodeIdentityVerifier.check(
            entitlements: ["com.apple.security.app-sandbox": true, "com.apple.security.get-task-allow": false], policy: policy
        ))
    }

    func testDisplayTextSanitization() {
        XCTAssertEqual(BrokerProtocol.sanitizedDisplayName("  Claude\u{202E}\u{200B} Code\n "), "Claude Code")
        XCTAssertEqual(BrokerProtocol.sanitizedDisplayName(String(repeating: "x", count: 500)).count, 64)
        XCTAssertEqual(BrokerProtocol.sanitizedDisplayName(nil), "Unnamed client")
        XCTAssertEqual(BrokerProtocol.sanitizedPurpose(String(repeating: "y", count: 1000)).count, 280)
    }
}
