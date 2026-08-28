import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SharedAutomationTests: XCTestCase {
    func testOwnerPublishesPortableDefinitionAndReceiverGetsDisabledTemplateData() async throws {
        let folder = try ClipFolder(name: "Sales Team", sortOrder: 0, createdAt: Date())
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [],
            deviceID: "owner-mac",
            transport: transport
        )
        let definition = try ClipFlow(
            name: "Research handoff",
            isEnabled: false,
            steps: [.openWeb(
                id: UUID(),
                template: "https://example.com/search?q={clip}",
                label: "CRM"
            )],
            sharedFolderID: folder.id
        )
        let snapshot = try await session.synchronizeAutomationDefinitions([definition])
        XCTAssertEqual(snapshot.automationDefinitions, [definition])
        XCTAssertEqual(snapshot.managedAutomationDefinitionIDs, [definition.id])
    }

    func testSharedDefinitionRejectsMachineSpecificApplicationBookmark() throws {
        let folderID = UUID()
        XCTAssertThrowsError(try ClipFlow(
            name: "Local app",
            steps: [.openApplication(
                id: UUID(),
                bookmarkData: Data([1, 2, 3]),
                displayName: "CRM"
            )],
            sharedFolderID: folderID
        ))
    }

    func testSharedDefinitionPreservesPortableCustomTextMatcher() async throws {
        let folder = try ClipFolder(name: "Sales Team", sortOrder: 0, createdAt: Date())
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [],
            deviceID: "owner-mac",
            transport: transport
        )
        let matcher = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b(enterprise|renewal)\b"#
        )
        let definition = try ClipFlow(
            name: "Enterprise follow-up",
            isEnabled: false,
            entityFilter: .customText,
            customMatcher: matcher,
            steps: [.addTags(id: UUID(), tags: ["enterprise"])],
            sharedFolderID: folder.id
        )

        let snapshot = try await session.synchronizeAutomationDefinitions([definition])
        XCTAssertEqual(snapshot.automationDefinitions.first?.customMatcher, matcher)
        XCTAssertTrue(snapshot.automationDefinitions.first?.matches(
            entities: [],
            clipText: "Enterprise account"
        ) == true)
    }

    func testSharedRecordRejectsLocalEnablementState() async throws {
        let folder = try ClipFolder(name: "Sales Team", sortOrder: 0, createdAt: Date())
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [],
            deviceID: "owner-mac",
            transport: transport
        )
        let enabled = try ClipFlow(
            name: "Enabled only here",
            isEnabled: true,
            steps: [.openWeb(
                id: UUID(),
                template: "https://example.com/search?q={clip}",
                label: "CRM"
            )],
            sharedFolderID: folder.id
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await session.synchronizeAutomationDefinitions([enabled])
        }
    }

    func testSharedDefinitionRejectsMoveOutsideWorkspaceGraph() async throws {
        let folder = try ClipFolder(name: "Sales Team", sortOrder: 0, createdAt: Date())
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [],
            deviceID: "owner-mac",
            transport: transport
        )
        let definition = try ClipFlow(
            name: "Escape workspace",
            isEnabled: false,
            steps: [.moveToFolder(id: UUID(), folderID: UUID())],
            sharedFolderID: folder.id
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await session.synchronizeAutomationDefinitions([definition])
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
