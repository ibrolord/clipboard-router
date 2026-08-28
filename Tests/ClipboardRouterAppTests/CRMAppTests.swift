import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class CRMAppTests: XCTestCase {
    func testConnectionDefinitionPersistsWithoutOAuthToken() throws {
        let suite = "CRMAppTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = makeModel(defaults: defaults)
        model.saveCRMConnection(definition())
        let persisted = String(data: try XCTUnwrap(defaults.data(forKey: "crmConnectionDefinitions.v1")), encoding: .utf8)!

        XCTAssertEqual([persisted.contains("client-id"), persisted.contains("access-token")], [true, false])
    }

    func testDisconnectDeletesCredentialsButRetainsDefinition() {
        let credentials = AppCRMCredentialStore(tokens: tokens())
        let model = makeModel(credentials: credentials)
        let definition = definition()
        model.saveCRMConnection(definition)

        model.disconnectCRMConnection(definition.id)

        XCTAssertEqual(
            CRMDisconnectObservation(
                definitionCount: model.crmConnectionDefinitions.count,
                credentialWasDeleted: credentials.value == nil,
                state: model.crmConnectionStates[definition.id]
            ),
            CRMDisconnectObservation(
                definitionCount: 1,
                credentialWasDeleted: true,
                state: .disconnected
            )
        )
    }

    func testHubSpotWithoutHTTPSTokenBrokerIsTruthfullyBlocked() {
        let model = makeModel()
        let definition = CRMConnectionDefinition(
            provider: .hubSpot,
            displayName: "HubSpot",
            clientID: "client-id",
            redirectURI: URL(string: "clipboardrouter://oauth/hubspot")!
        )

        model.saveCRMConnection(definition)

        XCTAssertEqual(model.crmConnectionStates[definition.id]?.label, "Setup required")
    }

    func testConnectedOrdinaryTextClipOpensEditableTaskReview() async throws {
        let content = try ClipContent.detect(text: "Follow up with Pat tomorrow")
        let saved = try SavedClip(name: "Follow up", content: content, createdAt: Date())
        let credentials = AppCRMCredentialStore(tokens: tokens())
        let model = makeModel(
            credentials: credentials,
            snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
        )
        let definition = definition()
        model.saveCRMConnection(definition)
        await model.start()
        let clip = PresentedClip(
            id: saved.id, title: saved.name, content: saved.content,
            date: saved.modifiedAt, sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )

        model.presentCRMReview(for: clip)

        XCTAssertEqual(
            model.pendingCRMReview.map { [$0.object.rawValue, $0.fields["subject"] ?? ""] },
            ["task", "Follow up"]
        )
    }

    func testRichTextAndLocationBearingClipsCannotOpenCRMReview() async throws {
        let rich = try ClipContent(type: .richText, text: "Rich")
        let plain = try ClipContent.detect(text: "Plain")
        let savedRich = try SavedClip(name: "Rich", content: rich, createdAt: Date())
        let savedLocated = try SavedClip(
            name: "Located", content: plain, createdAt: Date(),
            captureContext: ClipCaptureContext(
                sourceApplicationName: "Editor",
                sourceURL: nil,
                coarseLocation: try CoarseLocationContext(label: "Toronto, Ontario")
            )
        )
        let model = makeModel(
            credentials: AppCRMCredentialStore(tokens: tokens()),
            snapshot: ClipboardLibrarySnapshot(savedClips: [savedRich, savedLocated])
        )
        model.saveCRMConnection(definition())
        await model.start()
        let clips = [savedRich, savedLocated].map {
            PresentedClip(
                id: $0.id, title: $0.name, content: $0.content,
                date: $0.modifiedAt, sourceBundleIdentifier: nil,
                origin: .saved(folderID: nil), captureContext: $0.captureContext
            )
        }

        let decisions = clips.map(model.canSendToCRM)

        XCTAssertEqual(decisions, [false, false])
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        credentials: AppCRMCredentialStore = AppCRMCredentialStore(),
        snapshot: ClipboardLibrarySnapshot = .empty
    ) -> AppModel {
        let defaults = defaults ?? UserDefaults(suiteName: "CRMAppTests.\(UUID())")!
        return AppModel(
            defaults: defaults,
            hotKey: AppCRMHotKey(),
            crmCredentialStore: credentials,
            crmTransport: AppCRMTransport(),
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "CRMAppTests-\(UUID())", isDirectory: true
            ),
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: snapshot)
        )
    }

    private func definition() -> CRMConnectionDefinition {
        CRMConnectionDefinition(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            provider: .salesforce,
            displayName: "Salesforce",
            clientID: "client-id",
            redirectURI: URL(string: "clipboardrouter://oauth/salesforce")!
        )
    }

    private func tokens() -> CRMTokenSet {
        CRMTokenSet(
            accessToken: "access-token", refreshToken: "refresh-token",
            expiresAt: Date.distantFuture, accountID: "account",
            instanceURL: URL(string: "https://tenant.my.salesforce.com"), scopes: ["api"]
        )
    }
}

private struct CRMDisconnectObservation: Equatable {
    let definitionCount: Int
    let credentialWasDeleted: Bool
    let state: CRMConnectionState?
}

private final class AppCRMCredentialStore: CRMCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: CRMTokenSet?
    init(tokens: CRMTokenSet? = nil) { value = tokens }
    func load(connectionID: UUID) throws -> CRMTokenSet? { lock.withLock { value } }
    func save(_ tokens: CRMTokenSet, connectionID: UUID) throws { lock.withLock { value = tokens } }
    func delete(connectionID: UUID) throws { lock.withLock { value = nil } }
}

private struct AppCRMTransport: CRMHTTPTransport {
    func send(_: CRMHTTPRequest) async throws -> CRMHTTPResponse { throw CRMTransportError.offline }
}

@MainActor
private final class AppCRMHotKey: GlobalHotKeyRegistering {
    func register(_: GlobalHotKeyDescriptor, handler _: @escaping @MainActor () -> Void) throws {}
    func unregister() {}
}
