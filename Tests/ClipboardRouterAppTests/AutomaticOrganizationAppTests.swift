import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class AutomaticOrganizationAppTests: XCTestCase {
    func testMatcherEditorRoundTripsCustomModePatternAndCaseSensitivity() throws {
        for matcher in [
            try CustomClipTextMatcher(
                mode: .wordsOrPhrases,
                pattern: "Acme, Enterprise",
                isCaseSensitive: true
            ),
            try CustomClipTextMatcher(
                mode: .regularExpression,
                pattern: #"\bACME-\d{3}\b"#,
                isCaseSensitive: false
            )
        ] {
            let draft = AutomaticOrganizationMatcherDraft(matcher: .customText(matcher))
            XCTAssertEqual(try draft.validatedMatcher(), .customText(matcher))
        }
    }

    func testPreviewApplyOnceAndUndoRoundTripThroughAppModel() async throws {
        let folder = try ClipFolder(
            name: "Qualified",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let saved = try SavedClip(
            name: "Account",
            content: ClipContent.detect(text: "owner@example.com"),
            createdAt: Date(timeIntervalSince1970: 2),
            tags: ["new"]
        )
        let rule = try AutomaticOrganizationRule(
            name: "File emails",
            priority: 0,
            matcher: .entity(.emailAddress),
            action: AutomaticOrganizationAction(
                movesToFolder: true,
                destinationFolderID: folder.id,
                addedTags: ["qualified"]
            )
        )
        let organizationStore = InMemoryAutomaticOrganizationStore(
            snapshot: try AutomaticOrganizationSnapshot(rules: [rule])
        )
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(savedClips: [saved], folders: [folder]),
            organizationStore: organizationStore
        )
        await model.start()

        let clip = try XCTUnwrap(model.automaticOrganizationPreviewClips.first)
        let suggestion = try XCTUnwrap(model.automaticOrganizationSuggestions(for: clip).first)
        XCTAssertEqual(suggestion.reason, "Contains a detected email")
        model.applyAutomaticOrganizationOnce(suggestion, to: clip)

        let applied = await waitUntil {
            model.snapshot.savedClips.first?.folderID == folder.id
                && model.snapshot.savedClips.first?.tags == ["new", "qualified"]
        }
        XCTAssertTrue(applied)
        let receipt = try XCTUnwrap(model.latestAutomaticOrganizationReceipt(for: saved.id))
        model.undoAutomaticOrganization(receipt)

        let undone = await waitUntil {
            model.snapshot.savedClips.first?.folderID == nil
                && model.snapshot.savedClips.first?.tags == ["new"]
        }
        XCTAssertTrue(undone)
        XCTAssertNil(model.latestAutomaticOrganizationReceipt(for: saved.id))
    }

    func testAlwaysApplyRunsOnlyAfterLocalSaveAndNotDuringStartupLoad() async throws {
        let now = Date()
        let preexisting = try SavedClip(
            name: "Existing link",
            content: ClipContent.detect(text: "https://example.com/existing"),
            createdAt: now
        )
        let history = HistoryItem(
            content: try ClipContent.detect(text: "https://example.com/new"),
            createdAt: now.addingTimeInterval(1)
        )
        let rule = try AutomaticOrganizationRule(
            name: "Tag links",
            priority: 0,
            behavior: .alwaysApply,
            matcher: .contentType(.url),
            action: AutomaticOrganizationAction(addedTags: ["link"])
        )
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(history: [history], savedClips: [preexisting]),
            organizationStore: InMemoryAutomaticOrganizationStore(
                snapshot: try AutomaticOrganizationSnapshot(rules: [rule])
            )
        )
        await model.start()

        XCTAssertEqual(model.snapshot.savedClips.first?.tags, [])
        model.saveHistoryClip(PresentedClip(
            id: history.id,
            title: history.content.text,
            content: history.content,
            date: history.createdAt,
            sourceBundleIdentifier: nil,
            origin: .history
        ), folderID: nil)

        let automaticallyApplied = await waitUntil {
            model.snapshot.savedClips.first(where: {
                $0.sourceHistoryItemID == history.id
            })?.tags == ["link"]
        }
        XCTAssertTrue(
            automaticallyApplied,
            "error=\(model.errorMessage ?? "none") saved=\(model.snapshot.savedClips.map { ($0.sourceHistoryItemID, $0.content.type, $0.tags ?? []) })"
        )
        XCTAssertEqual(
            model.snapshot.savedClips.first(where: { $0.id == preexisting.id })?.tags,
            []
        )
    }

    func testRuleCreateEditToggleBehaviorReorderSuppressAndDeleteRoundTrip() async throws {
        let folder = try ClipFolder(
            name: "Qualified",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let store = InMemoryAutomaticOrganizationStore()
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(folders: [folder]),
            organizationStore: store
        )
        await model.start()

        let first = try AutomaticOrganizationRule(
            name: "First",
            priority: 0,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["first"])
        )
        let second = try AutomaticOrganizationRule(
            name: "Second",
            priority: 1,
            matcher: .contentType(.url),
            action: AutomaticOrganizationAction(addedTags: ["second"])
        )
        let didAddFirst = await model.addAutomaticOrganizationRule(first)
        let didAddSecond = await model.addAutomaticOrganizationRule(second)
        XCTAssertTrue(didAddFirst)
        XCTAssertTrue(didAddSecond)
        XCTAssertEqual(model.automaticOrganizationSnapshot.rules.map(\.id), [first.id, second.id])

        let edited = try AutomaticOrganizationRule(
            id: first.id,
            name: "Edited First",
            isEnabled: first.isEnabled,
            priority: first.priority,
            behavior: first.behavior,
            matcher: .domain("example.com"),
            action: AutomaticOrganizationAction(
                movesToFolder: true,
                destinationFolderID: folder.id,
                addedTags: ["qualified"]
            )
        )
        let didEdit = await model.updateAutomaticOrganizationRule(edited, expecting: first)
        XCTAssertTrue(didEdit)
        XCTAssertEqual(model.automaticOrganizationSnapshot.rules.first, edited)

        model.setAutomaticOrganizationRuleEnabled(edited.id, enabled: false)
        let didDisable = await waitUntil {
            model.automaticOrganizationSnapshot.rules.first?.isEnabled == false
        }
        XCTAssertTrue(didDisable)
        model.setAutomaticOrganizationRuleEnabled(edited.id, enabled: true)
        let didEnable = await waitUntil {
            model.automaticOrganizationSnapshot.rules.first?.isEnabled == true
        }
        XCTAssertTrue(didEnable)

        let enabledEdited = try XCTUnwrap(model.automaticOrganizationSnapshot.rules.first)
        let suggestion = AutomaticOrganizationSuggestion(
            rule: enabledEdited,
            reason: "Test",
            confidence: 100
        )
        model.neverSuggestAutomaticOrganization(suggestion)
        let didSuppress = await waitUntil {
            model.automaticOrganizationSnapshot.suppressedRuleIDs.contains(edited.id)
        }
        XCTAssertTrue(didSuppress)
        model.setAutomaticOrganizationRuleBehavior(edited.id, behavior: .alwaysApply)
        let didChangeBehavior = await waitUntil {
            model.automaticOrganizationSnapshot.rules.first?.behavior == .alwaysApply
                && !model.automaticOrganizationSnapshot.suppressedRuleIDs.contains(edited.id)
        }
        XCTAssertTrue(didChangeBehavior)

        model.moveAutomaticOrganizationRule(second.id, offset: -1)
        let didReorder = await waitUntil {
            model.automaticOrganizationSnapshot.rules.sorted(by: {
                $0.priority < $1.priority
            }).first?.id == second.id
        }
        XCTAssertTrue(didReorder)

        model.deleteAutomaticOrganizationRule(second.id)
        let didDelete = await waitUntil {
            model.automaticOrganizationSnapshot.rules.map(\.id) == [edited.id]
        }
        XCTAssertTrue(didDelete)
        let stored = try await store.load()
        XCTAssertEqual(stored, model.automaticOrganizationSnapshot)
    }

    func testRuleEditRejectsStaleSourceAndIneligibleDestinationWithoutMutation() async throws {
        let store = InMemoryAutomaticOrganizationStore()
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(),
            organizationStore: store
        )
        await model.start()

        let invalidDestination = try AutomaticOrganizationRule(
            name: "Missing folder",
            priority: 0,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(
                movesToFolder: true,
                destinationFolderID: UUID()
            )
        )
        let didAddInvalidDestination = await model.addAutomaticOrganizationRule(invalidDestination)
        XCTAssertFalse(didAddInvalidDestination)
        XCTAssertEqual(model.errorMessage, AutomaticOrganizationError.ineligibleDestination.localizedDescription)
        XCTAssertTrue(model.automaticOrganizationSnapshot.rules.isEmpty)

        let rule = try AutomaticOrganizationRule(
            name: "Current",
            priority: 0,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["current"])
        )
        let didAddRule = await model.addAutomaticOrganizationRule(rule)
        XCTAssertTrue(didAddRule)
        model.setAutomaticOrganizationRuleBehavior(rule.id, behavior: .alwaysApply)
        let didChangeBehavior = await waitUntil {
            model.automaticOrganizationSnapshot.rules.first?.behavior == .alwaysApply
        }
        XCTAssertTrue(didChangeBehavior)

        let staleReplacement = try AutomaticOrganizationRule(
            id: rule.id,
            name: "Stale edit",
            isEnabled: rule.isEnabled,
            priority: rule.priority,
            behavior: rule.behavior,
            matcher: .contentType(.image),
            action: AutomaticOrganizationAction(addedTags: ["stale"])
        )
        let didApplyStaleEdit = await model.updateAutomaticOrganizationRule(
            staleReplacement,
            expecting: rule
        )
        XCTAssertFalse(didApplyStaleEdit)
        XCTAssertEqual(model.errorMessage, AutomaticOrganizationError.staleRule.localizedDescription)
        XCTAssertEqual(model.automaticOrganizationSnapshot.rules.first?.name, "Current")
        XCTAssertEqual(model.automaticOrganizationSnapshot.rules.first?.behavior, .alwaysApply)
        let stored = try await store.load()
        XCTAssertEqual(stored, model.automaticOrganizationSnapshot)
    }

    private func makeModel(
        snapshot: ClipboardLibrarySnapshot,
        organizationStore: any AutomaticOrganizationPersisting
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "AutomaticOrganizationAppTests.\(UUID())")!,
            hotKey: AutomaticOrganizationNoopHotKeyRegistrar(),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AutomaticOrganizationAppTests-\(UUID())"),
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: snapshot),
            automaticOrganizationStore: organizationStore
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class AutomaticOrganizationNoopHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
