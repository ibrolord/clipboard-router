import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSync
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class CloudPushAppTests: XCTestCase {
    func testAcceptedPushHintRefreshNeverWritesPasteboard() async throws {
        let containerIdentifier = "iCloud.com.example.ClipboardRouter"
        let textWriter = PushTextPasteboardWriter()
        let typedWriter = PushTypedPasteboardWriter()
        let coordinator = CloudPushSubscriptionCoordinator(
            containerIdentifier: containerIdentifier,
            environment: .development,
            client: UnusedPushSubscriptionClient(),
            store: InMemoryCloudPushInstallationStateStore()
        )
        let model = AppModel(
            defaults: UserDefaults(suiteName: "CloudPushAppTests.\(UUID())")!,
            pasteboardWriter: textWriter,
            typedPasteboardWriter: typedWriter,
            hotKey: PushNoopHotKeyRegistrar(),
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "CloudPushAppTests-\(UUID())",
                isDirectory: true
            ),
            cloudPushSubscriptionCoordinator: coordinator,
            cloudPushNotificationDecoder: StubPushNotificationDecoder(
                notification: CloudPushNotification(
                    containerIdentifier: containerIdentifier,
                    subscriptionID: CloudPushSubscriptionIdentifiers.identifier(for: .private),
                    databaseScope: .private
                )
            ),
            libraryPersistence: InMemoryClipboardLibraryStore()
        )

        let accepted = await model.receiveCloudKitRemoteNotification(["ck": "hint"])

        XCTAssertEqual(
            PushPasteboardObservation(
                accepted: accepted,
                textWrites: textWriter.writeCount,
                typedWrites: typedWriter.writeCount
            ),
            PushPasteboardObservation(accepted: true, textWrites: 0, typedWrites: 0)
        )
    }
}

private struct PushPasteboardObservation: Equatable {
    let accepted: Bool
    let textWrites: Int
    let typedWrites: Int
}

private struct StubPushNotificationDecoder: CloudPushNotificationDecoding {
    let notification: CloudPushNotification?

    func decode(_: [AnyHashable: Any]) -> CloudPushNotification? { notification }
}

private actor UnusedPushSubscriptionClient: CloudPushSubscriptionClient {
    func accountIdentity() async throws -> SyncAccountIdentity {
        XCTFail("Push receipt must not install subscriptions")
        return SyncAccountIdentity(state: .available, fingerprint: "unused")
    }

    func subscription(
        id _: String,
        in _: CloudPushDatabaseScope
    ) async throws -> CloudPushRemoteSubscription? {
        XCTFail("Push receipt must not inspect subscriptions")
        return nil
    }

    func saveSilentDatabaseSubscription(
        id _: String,
        in _: CloudPushDatabaseScope
    ) async throws {
        XCTFail("Push receipt must not save subscriptions")
    }

    func deleteSubscription(id _: String, in _: CloudPushDatabaseScope) async throws {
        XCTFail("Push receipt must not delete subscriptions")
    }
}

@MainActor
private final class PushTextPasteboardWriter: PasteboardWriting {
    private(set) var writeCount = 0

    func writeForRouting(_: String) -> Bool {
        writeCount += 1
        return true
    }
}

@MainActor
private final class PushTypedPasteboardWriter: TypedPasteboardWriting {
    private(set) var writeCount = 0

    func write(_: ClipContent, mode _: ClipPasteboardWriteMode) async throws {
        writeCount += 1
    }

    func write(
        _: ClipContent,
        mode _: ClipPasteboardWriteMode,
        sourceTypeIdentifiers _: [String]
    ) async throws {
        writeCount += 1
    }
}

@MainActor
private final class PushNoopHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
