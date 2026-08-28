import ClipboardRouterCore
import XCTest
@testable import ClipboardRouterSync

final class SensitiveContentBoundaryTests: XCTestCase {
    func testSensitiveSavedClipIsLocalOnlyForPersonalAndSharedSync() async throws {
        let folder = try ClipFolder(name: "Sensitive", sortOrder: 0, createdAt: .distantPast)
        let clip = try SavedClip(
            name: "Detected secret",
            content: ClipContent.detect(text: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"),
            folderID: folder.id,
            createdAt: .distantPast,
            sensitivity: ClipSensitivityMetadata(
                category: "openAIAPIKey",
                confidence: 100,
                detectorVersion: 1
            )
        )
        let policy = SyncEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(.savedClip(clip, metadata: .ready)),
            .localOnly(.sensitiveContentRequiresExplicitConsent)
        )

        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        do {
            _ = try await coordinator.recordSavedClip(clip)
            XCTFail("Expected the sensitive saved clip to remain local")
        } catch {
            XCTAssertEqual(
                error as? SavedLibrarySyncError,
                .ineligible(clip.id, .sensitiveContentRequiresExplicitConsent)
            )
        }

        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let shared = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "mac-a",
            participants: [try SharedFolderParticipant(id: "owner", role: .owner)]
        )
        do {
            _ = try await shared.recordSavedClip(clip)
            XCTFail("Expected the sensitive saved clip to remain outside collaboration")
        } catch {
            XCTAssertEqual(
                error as? SharedFolderError,
                .ineligible(clip.id, .sensitiveContentRequiresExplicitConsent)
            )
        }
    }
}
