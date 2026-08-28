import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testMenuBarClipLimitDefaultsPersistsAndReloads() throws {
        let defaults = try isolatedDefaults()
        let supportDirectory = temporarySupportDirectory()
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: supportDirectory
        )

        XCTAssertEqual(model.menuBarClipLimit, 15)
        model.setMenuBarClipLimit(742)
        XCTAssertEqual(model.menuBarClipLimit, 742)

        let reloaded = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: supportDirectory
        )
        XCTAssertEqual(reloaded.menuBarClipLimit, 742)

        reloaded.setMenuBarClipLimit(0)
        XCTAssertEqual(reloaded.menuBarClipLimit, 1)
        reloaded.setMenuBarClipLimit(1_001)
        XCTAssertEqual(reloaded.menuBarClipLimit, 1_000)
    }

    func testMenuBarClipLimitIsOneBudgetAcrossPinnedAndRecent() async throws {
        let now = Date()
        let pinned = try (0..<3).map { index in
            try SavedClip(
                name: "Pinned \(index)",
                content: ClipContent.detect(text: "Pinned content \(index)"),
                createdAt: now.addingTimeInterval(TimeInterval(index)),
                modifiedAt: now.addingTimeInterval(TimeInterval(index)),
                pinnedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let history = try (0..<8).map { index in
            HistoryItem(
                content: try ClipContent.detect(text: "Recent content \(index)"),
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: history, savedClips: pinned)
            )
        )
        await model.start()
        model.setMenuBarClipLimit(5)

        XCTAssertEqual(model.menuBarPinnedClips.count, 3)
        XCTAssertEqual(model.menuBarRecentClips.count, 2)
        XCTAssertEqual(model.menuBarPinnedClips.count + model.menuBarRecentClips.count, 5)

        model.updateMenuSearch("content")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.menuSearchResults.count, 5)
    }

    func testMenuBarCanScrollAndSearchOneThousandClips() async throws {
        let now = Date()
        let history = try (0..<1_005).map { index in
            HistoryItem(
                content: try ClipContent.detect(text: "Scrollable menu item \(index)"),
                createdAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: history)
            )
        )
        await model.start()
        model.setMenuBarClipLimit(1_000)

        XCTAssertEqual(model.menuBarRecentClips.count, 1_000)

        model.updateMenuSearch("Scrollable menu item")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.menuSearchResults.count, 1_000)
    }

    func testLaunchAtLoginUsesSystemStateAndRegistersWithoutPersistingPreference() throws {
        let defaults = try isolatedDefaults()
        let service = FakeLaunchAtLoginService(state: .off)
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            launchAtLoginService: service,
            supportDirectory: temporarySupportDirectory()
        )

        XCTAssertEqual(model.launchAtLoginState, .off)
        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(model.launchAtLoginState, .on)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))
    }

    func testLaunchAtLoginSurfacesApprovalAndCanUnregisterPendingRequest() throws {
        let service = FakeLaunchAtLoginService(
            state: .off,
            stateAfterRegistration: .requiresApproval
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            launchAtLoginService: service,
            supportDirectory: temporarySupportDirectory()
        )

        model.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(model.launchAtLoginState, .requiresApproval)
        XCTAssertNotNil(model.statusMessage)

        model.setLaunchAtLoginEnabled(false)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(model.launchAtLoginState, .off)
    }

    func testLaunchAtLoginFailureKeepsAuthoritativeSystemState() throws {
        let service = FakeLaunchAtLoginService(state: .off, registrationError: .failure)
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            launchAtLoginService: service,
            supportDirectory: temporarySupportDirectory()
        )

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(model.launchAtLoginState, .off)
        XCTAssertNotNil(model.errorMessage)

        service.simulateRegistrationError(nil)
        model.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(model.launchAtLoginState, .on)
        XCTAssertNil(model.errorMessage)
    }

    func testLaunchAtLoginRefreshesSystemStateBeforeMutation() throws {
        let service = FakeLaunchAtLoginService(state: .off)
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            launchAtLoginService: service,
            supportDirectory: temporarySupportDirectory()
        )
        service.simulateExternalStateChange(to: .on)

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(model.launchAtLoginState, .on)
    }

    func testLaunchAtLoginUnregisterFailureKeepsAuthoritativeSystemState() throws {
        let service = FakeLaunchAtLoginService(state: .on, unregistrationError: .failure)
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            launchAtLoginService: service,
            supportDirectory: temporarySupportDirectory()
        )

        model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(model.launchAtLoginState, .on)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAssistantPresetReplacesAnUneditedPresetTemplate() {
        let rewrite = AssistantPromptTemplatePolicy.selecting(
            template: AssistantPurpose.rewrite.promptTemplate,
            currentPrompt: "",
            lastAppliedTemplate: nil
        )
        let format = AssistantPromptTemplatePolicy.selecting(
            template: AssistantPurpose.format.promptTemplate,
            currentPrompt: rewrite.prompt,
            lastAppliedTemplate: rewrite.lastAppliedTemplate
        )

        XCTAssertEqual(format.prompt, AssistantPurpose.format.promptTemplate)
        XCTAssertEqual(format.lastAppliedTemplate, AssistantPurpose.format.promptTemplate)
    }

    func testAssistantPresetPreservesUserEditedPrompt() {
        let selection = AssistantPromptTemplatePolicy.selecting(
            template: AssistantPurpose.research.promptTemplate,
            currentPrompt: "Compare these notes with the renewal call.",
            lastAppliedTemplate: AssistantPurpose.rewrite.promptTemplate
        )

        XCTAssertEqual(selection.prompt, "Compare these notes with the renewal call.")
        XCTAssertNil(selection.lastAppliedTemplate)
    }

    func testMenuBarRoutesPanelsToContinuationWindowAndRevealToLibrary() {
        let assistant = SuggestedClipAction(kind: .askAI, entity: nil)
        let related = SuggestedClipAction(kind: .findRelated, entity: nil)
        let immediate = SuggestedClipAction(kind: .openLink, entity: nil)

        XCTAssertEqual(MenuBarActionPresentationPolicy.surface(for: assistant), .menuBar)
        XCTAssertEqual(MenuBarActionPresentationPolicy.surface(for: related), .library)
        XCTAssertEqual(MenuBarActionPresentationPolicy.surface(for: immediate), .menuBar)
        XCTAssertEqual(MenuBarActionPresentationPolicy.debugBundleSurface, .library)
        XCTAssertEqual(LibraryWindowPresenter.activationPolicy, .regular)
    }

    func testOpeningClipToolsSelectsTheClipToolsWorkspace() throws {
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )

        model.openActionsWorkspace(.pasteTools)

        XCTAssertEqual(model.selectedSection, .workflows)
        XCTAssertEqual(model.actionsWorkspaceMode, .pasteTools)
    }

    func testMenuBarContinuationDelegatesLifetimeToPersistentPresenter() throws {
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        let presenter = FakeMenuBarContinuationPresenter()
        model.registerMenuBarContinuationPresenter(presenter)

        model.presentMenuBarContinuation(.quickPaste)

        XCTAssertEqual(presenter.presentCallCount, 1)
        XCTAssertTrue(presenter.hasActiveRequest)
        model.dismissMenuBarContinuation()
        XCTAssertEqual(presenter.dismissCallCount, 1)
        XCTAssertFalse(presenter.hasActiveRequest)
    }

    func testMenuBarContinuationReportsWhenPresenterRejectsSecondRequest() throws {
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        let presenter = FakeMenuBarContinuationPresenter()
        model.registerMenuBarContinuationPresenter(presenter)

        model.presentMenuBarContinuation(.quickPaste)
        model.presentMenuBarContinuation(.noteEditor(NoteEditorRequest(mode: .create)))

        XCTAssertEqual(presenter.presentCallCount, 2)
        XCTAssertTrue(presenter.hasActiveRequest)
        XCTAssertNotNil(model.statusMessage)
    }

    func testPresentationRequestsRecordTheirIntendedSurface() throws {
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )

        model.requestCreateNote(presentationSurface: .menuBar)
        model.requestInsertPalette(presentationSurface: .menuBar)

        XCTAssertEqual(model.noteCreationRequestID, 1)
        XCTAssertEqual(model.noteCreationPresentationSurface, .menuBar)
        XCTAssertEqual(model.insertPaletteRequestID, 1)
        XCTAssertEqual(model.insertPalettePresentationSurface, .menuBar)
    }

    func testInsertAliasPersistsAndResolvesSavedNoteWithoutPersistingContent() async throws {
        let defaults = try isolatedDefaults()
        let saved = try SavedClip(
            kind: .note,
            name: "Pricing reply",
            content: ClipContent.detect(text: "Approved pricing language"),
            createdAt: Date()
        )
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(LibrarySection.allSaved)
        let clip: PresentedClip = try XCTUnwrap(model.clipsForSelectedSection.first)

        XCTAssertTrue(model.saveInsertAlias(
            for: clip,
            abbreviation: ";Pricing",
            delivery: InsertAliasDelivery.copy
        ))
        let result: InsertAliasResult = try XCTUnwrap(
            model.insertAliasResults(matching: ";pricing").first
        )
        XCTAssertEqual(result.alias?.trigger, ";pricing")
        XCTAssertEqual(result.clip.id, saved.id)

        let data = try XCTUnwrap(defaults.data(forKey: "insertAliases.v1"))
        let serialized = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(serialized.contains("Approved pricing language"))
        XCTAssertTrue(serialized.contains(saved.id.uuidString))
    }

    func testQuickPasteEmptyQueryShowsPinnedThenRecentEligibleSavedItems() async throws {
        let defaults = try isolatedDefaults()
        let now = Date(timeIntervalSince1970: 90_000)
        let olderPinned = try SavedClip(
            kind: .note,
            name: "Pinned note",
            content: ClipContent.detect(text: "Pinned text"),
            createdAt: now.addingTimeInterval(-300),
            modifiedAt: now.addingTimeInterval(-200),
            pinnedAt: now.addingTimeInterval(-100)
        )
        let recent = try SavedClip(
            name: "Recent clip",
            content: ClipContent.detect(text: "Recent text"),
            createdAt: now.addingTimeInterval(-20),
            modifiedAt: now.addingTimeInterval(-10)
        )
        let locationBearing = try SavedClip(
            name: "Located clip",
            content: ClipContent.detect(text: "Do not offer this in Quick Paste"),
            createdAt: now,
            captureContext: ClipCaptureContext(
                coarseLocation: try CoarseLocationContext(label: "Toronto")
            )
        )
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [recent, olderPinned, locationBearing])
            )
        )
        await model.start()

        let results = model.insertAliasResults(matching: "")

        XCTAssertEqual(results.map(\.clip.id), [olderPinned.id, recent.id])
    }

    func testQuickPasteHidesPersistedAliasWhenItsSavedItemBecomesIneligible() async throws {
        let defaults = try isolatedDefaults()
        let located = try SavedClip(
            kind: .note,
            name: "Located note",
            content: ClipContent.detect(text: "Private trip follow-up"),
            createdAt: Date(timeIntervalSince1970: 91_000),
            captureContext: ClipCaptureContext(
                coarseLocation: try CoarseLocationContext(label: "Toronto")
            )
        )
        let alias = try InsertAlias(
            name: located.name,
            abbreviation: "trip",
            savedClipID: located.id,
            delivery: .copy
        )
        defaults.set(try JSONEncoder().encode([alias]), forKey: "insertAliases.v1")
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [located])
            )
        )
        await model.start()

        XCTAssertTrue(model.insertAliasResults(matching: ";trip").isEmpty)
    }

    func testSuggestedActionsReserveAssistantSlotWhenDetectedActionsReachLimit() async throws {
        let saved = try SavedClip(
            name: "Prospects",
            content: ClipContent.detect(
                text: "one@example.com two@example.com three@example.com four@example.com"
            ),
            createdAt: Date(timeIntervalSince1970: 92_000)
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        let actions = model.suggestedActions(for: clip)

        XCTAssertEqual(actions.count, 8)
        XCTAssertEqual(actions.last?.kind, .askAI)
    }

    func testRichTextClipOffersAssistantUsingFlattenedText() async throws {
        let saved = try SavedClip(
            name: "Browser research",
            content: ClipContent(
                type: .richText,
                text: "Acme renewal is Tuesday"
            ),
            createdAt: Date(timeIntervalSince1970: 93_000)
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        XCTAssertTrue(model.canPresentAssistant(for: clip))
        XCTAssertEqual(model.suggestedActions(for: clip).map(\.kind), [.askAI])
    }

    func testCombinedClipsCloudAssistantSendsOnlyReviewedMarkdown() async throws {
        let client = FakeHostedAssistantClient()
        let first = try SavedClip(
            name: "Account summary",
            content: ClipContent.detect(text: "Acme renewal is Tuesday"),
            createdAt: Date(timeIntervalSince1970: 93_100)
        )
        let second = try SavedClip(
            name: "Decision maker",
            content: ClipContent.detect(text: "Jordan owns procurement"),
            createdAt: Date(timeIntervalSince1970: 93_200)
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hostedAssistant: client,
            hostedAssistantCredentialStore: FakeHostedCredentialStore(
                apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz"
            ),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [first, second])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        for clip in model.clipsForSelectedSection {
            model.addToCombinedClips(clip)
        }
        model.prepareCombinedClipsReview()
        let request = try XCTUnwrap(model.pendingCombinedClipsReview)
        let reviewedMarkdown = try XCTUnwrap(model.combinedClipsMarkdown(for: request))
        model.isHostedAssistantConsentGranted = true

        let response = await model.askCombinedClipsAssistant(
            prompt: "Summarize",
            messages: [],
            purpose: .quickAnswer,
            engine: .fastCloud,
            request: request
        )

        XCTAssertEqual(response?.text, "draft")
        let hostedRequest = await client.lastRequest
        XCTAssertEqual(hostedRequest?.context, reviewedMarkdown)
        XCTAssertEqual(hostedRequest?.prompt, "Summarize")
    }

    func testHostedAssistantRequiresConsentAndRejectsPrivateSourceBeforeClientCall() async throws {
        let client = FakeHostedAssistantClient()
        let credentials = FakeHostedCredentialStore(apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz")
        let defaults = try isolatedDefaults()
        let model = AppModel(
            defaults: defaults,
            hostedAssistant: client,
            hostedAssistantCredentialStore: credentials,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        let privateClip = PresentedClip(
            id: UUID(),
            title: "Private",
            content: try ClipContent.detect(text: "private draft"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )
        model.isHostedAssistantConsentGranted = true

        let response = await model.askAssistant(
            prompt: "Summarize",
            messages: [],
            purpose: .quickAnswer,
            engine: .fastCloud,
            sourceClip: privateClip
        )

        XCTAssertNil(response)
        let callCount = await client.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLocationMetadataKeepsOnDeviceAssistantAvailableButBlocksCloud() async throws {
        let client = FakeHostedAssistantClient()
        let localAI = FakeLocalAIProcessor(response: "local answer")
        let saved = try SavedClip(
            name: "Located research",
            content: ClipContent.detect(text: "Acme renewal is Tuesday"),
            createdAt: Date(),
            captureContext: ClipCaptureContext(
                coarseLocation: try CoarseLocationContext(label: "America/Toronto")
            )
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            aiProcessor: localAI,
            hostedAssistant: client,
            hostedAssistantCredentialStore: FakeHostedCredentialStore(
                apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz"
            ),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        XCTAssertTrue(model.canPresentAssistant(for: clip))
        XCTAssertEqual(model.suggestedActions(for: clip).map(\.kind), [.askAI])
        let localResponse = await model.askOnDeviceAI("Summarize", sourceClip: clip)
        XCTAssertEqual(localResponse, "local answer")

        model.isHostedAssistantConsentGranted = true
        let cloud = await model.askAssistant(
            prompt: "Summarize",
            messages: [],
            purpose: .quickAnswer,
            engine: .fastCloud,
            sourceClip: clip
        )
        XCTAssertNil(cloud)
        let locationCloudCallCount = await client.callCount
        XCTAssertEqual(locationCloudCallCount, 0)
    }

    func testAssistantEntryRemainsDiscoverableWhenSourceNeedsOnDeviceAI() async throws {
        let saved = try SavedClip(
            name: "Located research",
            content: ClipContent.detect(text: "Acme renewal is Tuesday"),
            createdAt: Date(),
            captureContext: ClipCaptureContext(
                coarseLocation: try CoarseLocationContext(label: "America/Toronto")
            )
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            aiProcessor: FakeLocalAIProcessor(
                response: "unused",
                availability: .appleIntelligenceUnavailable
            ),
            hostedAssistantCredentialStore: FakeHostedCredentialStore(apiKey: nil),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        XCTAssertTrue(model.canPresentAssistant(for: clip))
        XCTAssertTrue(model.suggestedActions(for: clip).contains { $0.kind == .askAI })
        model.presentAssistant(for: clip)
        XCTAssertNotNil(model.pendingAIAssistant)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.cloudAssistantUnavailableReason(for: clip).contains("location metadata"))
    }

    func testBlankHostedAssistantModelFailsClosedBeforeClientCall() async throws {
        let client = FakeHostedAssistantClient()
        let saved = try SavedClip(
            name: "Research",
            content: ClipContent.detect(text: "ordinary context"),
            createdAt: Date()
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hostedAssistant: client,
            hostedAssistantCredentialStore: FakeHostedCredentialStore(
                apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz"
            ),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)
        model.isHostedAssistantConsentGranted = true
        model.hostedAssistantModel = "   "

        XCTAssertFalse(model.isHostedAssistantModelValid)
        let blankModelResponse = await model.askAssistant(
            prompt: "Summarize",
            messages: [],
            purpose: .quickAnswer,
            engine: .fastCloud,
            sourceClip: clip
        )
        XCTAssertNil(blankModelResponse)
        let blankModelCallCount = await client.callCount
        XCTAssertEqual(blankModelCallCount, 0)
        model.restoreDefaultHostedAssistantModel()
        XCTAssertEqual(model.hostedAssistantModel, "gpt-5-nano")
        XCTAssertTrue(model.isHostedAssistantModelValid)
    }

    func testVaultRecoveryRequiresExactAuthenticatedPayloadMatch() throws {
        let date = Date(timeIntervalSince1970: 42_000)
        let content = try ClipContent.detect(text: "recovery payload")
        let saved = try SavedClip(
            name: "Protected",
            content: content,
            createdAt: date,
            modifiedAt: date
        )
        let matching = try VaultItem(
            id: saved.id,
            name: saved.name,
            content: saved.content,
            createdAt: saved.createdAt,
            modifiedAt: saved.modifiedAt
        )
        let mismatched = try VaultItem(
            id: saved.id,
            name: saved.name,
            content: ClipContent(type: .plainText, text: "different payload"),
            createdAt: saved.createdAt,
            modifiedAt: saved.modifiedAt
        )

        XCTAssertTrue(AppModel.vaultItem(matching, exactlyMatches: saved))
        XCTAssertFalse(AppModel.vaultItem(mismatched, exactlyMatches: saved))
    }

    func testVaultRecoveryWithProvenanceRequiresExactSavedAndHistorySources() throws {
        let date = Date(timeIntervalSince1970: 43_000)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "source payload"),
            createdAt: date,
            sourceApplicationBundleIdentifier: "com.example.source",
            originatingDeviceIdentifier: "device-a",
            pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
        )
        let saved = try SavedClip(
            name: "Saved source",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date,
            sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: history.originatingDeviceIdentifier,
            originallyCapturedAt: history.createdAt,
            pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
        )
        let savedProvenance = VaultItemProvenance(
            ordinaryOrigin: .saved,
            sourceHistoryItemID: history.id,
            sourceSavedClipID: saved.id,
            linkedSavedClipIDs: [saved.id],
            sourceApplicationBundleIdentifier: saved.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: saved.originatingDeviceIdentifier,
            originallyCapturedAt: saved.originallyCapturedAt,
            pasteboardTypeIdentifiers: saved.pasteboardTypeIdentifiers ?? []
        )
        let savedVaultItem = try VaultItem(
            id: saved.id,
            name: saved.name,
            content: saved.content,
            createdAt: saved.createdAt,
            modifiedAt: saved.modifiedAt,
            provenance: savedProvenance
        )
        let wrongSavedSource = try VaultItem(
            id: saved.id,
            name: saved.name,
            content: saved.content,
            createdAt: saved.createdAt,
            modifiedAt: saved.modifiedAt,
            provenance: VaultItemProvenance(
                ordinaryOrigin: .saved,
                sourceHistoryItemID: history.id,
                sourceSavedClipID: UUID()
            )
        )

        XCTAssertTrue(AppModel.vaultItem(savedVaultItem, exactlyMatches: saved))
        XCTAssertFalse(AppModel.vaultItem(wrongSavedSource, exactlyMatches: saved))

        let historyVaultItem = try VaultItem(
            id: history.id,
            name: history.content.text,
            content: history.content,
            createdAt: history.createdAt,
            modifiedAt: history.modifiedAt,
            provenance: VaultItemProvenance(
                ordinaryOrigin: .history,
                sourceHistoryItemID: history.id,
                sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: history.originatingDeviceIdentifier,
                originallyCapturedAt: history.createdAt,
                pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
            )
        )
        XCTAssertTrue(AppModel.vaultItem(historyVaultItem, exactlyMatches: history))
    }

    func testShortcutChoicePersistsAfterSuccessfulRegistration() throws {
        let defaults = try isolatedDefaults()
        let registrar = FakeHotKeyRegistrar()
        let model = AppModel(
            defaults: defaults,
            hotKey: registrar,
            supportDirectory: temporarySupportDirectory()
        )

        model.setGlobalHotKeyChoice(.commandOptionV)

        XCTAssertEqual(model.globalHotKeyChoice, .commandOptionV)
        XCTAssertEqual(
            defaults.string(forKey: "globalHotKeyChoice.v1"),
            GlobalHotKeyChoice.commandOptionV.rawValue
        )
        XCTAssertEqual(
            registrar.registeredDescriptors,
            [GlobalHotKeyChoice.commandOptionV.descriptor]
        )
    }

    func testShortcutConflictRollsBackWithoutPersistingRejectedChoice() throws {
        let defaults = try isolatedDefaults()
        let registrar = FakeHotKeyRegistrar(
            failingDescriptor: GlobalHotKeyChoice.commandOptionV.descriptor
        )
        let model = AppModel(
            defaults: defaults,
            hotKey: registrar,
            supportDirectory: temporarySupportDirectory()
        )

        model.setGlobalHotKeyChoice(GlobalHotKeyChoice.commandOptionV)

        XCTAssertEqual(model.globalHotKeyChoice, GlobalHotKeyChoice.commandShiftV)
        XCTAssertNil(defaults.string(forKey: "globalHotKeyChoice.v1"))
        XCTAssertEqual(
            registrar.registeredDescriptors,
            [
                GlobalHotKeyChoice.commandOptionV.descriptor,
                GlobalHotKeyChoice.commandShiftV.descriptor,
            ]
        )
        XCTAssertNotNil(model.errorMessage)
    }

    func testSecurePasteTimeoutAcceptsOnlySupportedPersistedChoices() throws {
        let defaults = try isolatedDefaults()
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )

        model.setSecurePasteTimeout(seconds: 30)
        model.setSecurePasteTimeout(seconds: 31)

        XCTAssertEqual(model.securePasteTimeoutSeconds, 30)
        XCTAssertEqual(defaults.integer(forKey: "securePasteTimeoutSeconds.v1"), 30)
    }

    func testManualWebAutomationPersistsAndRemainsUserTriggered() throws {
        let defaults = try isolatedDefaults()
        let folderID = UUID()
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )

        XCTAssertTrue(model.addWebAutomation(
            name: "Search account portal",
            filter: .email,
            folderID: folderID,
            template: "https://example.com/search?q={email}"
        ))
        XCTAssertEqual(model.clipAutomations.count, 1)
        XCTAssertTrue(model.clipAutomations[0].isEnabled)

        let reloaded = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        XCTAssertEqual(reloaded.clipAutomations, model.clipAutomations)

        reloaded.setAutomationEnabled(reloaded.clipAutomations[0].id, enabled: false)
        XCTAssertFalse(reloaded.clipAutomations[0].isEnabled)
        let automationID = reloaded.clipAutomations[0].id
        XCTAssertTrue(reloaded.updateWebAutomation(
            id: automationID,
            name: "Search CRM",
            filter: .link,
            folderID: nil,
            template: "https://example.com/accounts?q={url}"
        ))
        XCTAssertEqual(reloaded.clipAutomations[0].id, automationID)
        XCTAssertEqual(reloaded.clipAutomations[0].name, "Search CRM")
        XCTAssertFalse(reloaded.clipAutomations[0].isEnabled)
        reloaded.deleteAutomation(automationID)
        XCTAssertTrue(reloaded.clipAutomations.isEmpty)
    }

    func testUnsafeAutomationAndPrivateSessionActionsFailClosed() throws {
        let defaults = try isolatedDefaults()
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        XCTAssertFalse(model.addWebAutomation(
            name: "Unsafe",
            filter: .any,
            folderID: nil,
            template: "file:///tmp/{clip}"
        ))
        XCTAssertTrue(model.clipAutomations.isEmpty)

        let privateClip = PresentedClip(
            id: UUID(),
            title: "sam@example.com",
            content: try ClipContent.detect(text: "sam@example.com on August 15, 2026"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )
        XCTAssertTrue(model.suggestedActions(for: privateClip).isEmpty)
        XCTAssertTrue(model.applicableAutomations(for: privateClip).isEmpty)

        let staleHistoryClip = PresentedClip(
            id: UUID(),
            title: "sam@example.com",
            content: try ClipContent.detect(text: "sam@example.com"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .history
        )
        XCTAssertTrue(model.suggestedActions(for: staleHistoryClip).isEmpty)
        XCTAssertTrue(model.applicableAutomations(for: staleHistoryClip).isEmpty)
    }

    func testCustomFlowPersistsAndCanBeDisabledOrDeleted() throws {
        let defaults = try isolatedDefaults()
        let folderID = UUID()
        let model = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )

        XCTAssertTrue(model.addFlow(
            name: "Prepare CRM follow-up",
            trigger: .folderEntry(folderID: folderID, includeDescendants: true),
            filter: .email,
            steps: [
                .addTags(id: UUID(), tags: ["qualified"]),
                .openWeb(
                    id: UUID(),
                    template: "https://example.com/search?q={email}",
                    label: "CRM"
                ),
            ]
        ))
        XCTAssertEqual(model.clipFlows.count, 1)
        XCTAssertTrue(model.clipFlows[0].requiresReviewWhenTriggered)

        let reloaded = AppModel(
            defaults: defaults,
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory()
        )
        XCTAssertEqual(reloaded.clipFlows, model.clipFlows)

        let id = try XCTUnwrap(reloaded.clipFlows.first?.id)
        reloaded.setFlowEnabled(id, enabled: false)
        XCTAssertFalse(reloaded.clipFlows[0].isEnabled)
        XCTAssertTrue(reloaded.updateFlow(
            id: id,
            name: "Prepare reviewed follow-up",
            trigger: .manual,
            filter: .link,
            steps: [.addTags(id: UUID(), tags: ["reviewed"])]
        ))
        XCTAssertEqual(reloaded.clipFlows[0].id, id)
        XCTAssertEqual(reloaded.clipFlows[0].name, "Prepare reviewed follow-up")
        XCTAssertFalse(reloaded.clipFlows[0].isEnabled)
        reloaded.deleteFlow(id)
        XCTAssertTrue(reloaded.clipFlows.isEmpty)
    }

    func testCustomTextFlowAppearsOnlyForMatchingSavedClip() async throws {
        let matching = try SavedClip(
            name: "Acme renewal",
            content: ClipContent.detect(text: "Enterprise renewal discussion"),
            createdAt: Date()
        )
        let other = try SavedClip(
            name: "Personal reminder",
            content: ClipContent.detect(text: "Buy groceries after work"),
            createdAt: Date().addingTimeInterval(1)
        )
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [matching, other])
            )
        )
        let matcher = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b(enterprise|renewal)\b"#
        )
        XCTAssertTrue(model.addFlow(
            name: "Enterprise follow-up",
            trigger: .manual,
            filter: .customText,
            customMatcher: matcher,
            steps: [.addTags(id: UUID(), tags: ["enterprise"])]
        ))

        await model.start()
        model.selectLibrarySection(.allSaved)
        let matchingClip = try XCTUnwrap(model.clipsForSelectedSection.first { $0.title == "Acme renewal" })
        let otherClip = try XCTUnwrap(model.clipsForSelectedSection.first { $0.title == "Personal reminder" })

        XCTAssertEqual(model.applicableFlows(for: matchingClip).map(\.name), ["Enterprise follow-up"])
        XCTAssertTrue(model.applicableFlows(for: otherClip).isEmpty)
    }

    func testConcurrentStartCallsShareOneStartupOperation() async throws {
        let persistence = CountingClipboardLibraryStore()
        let model = AppModel(
            defaults: try isolatedDefaults(),
            hotKey: FakeHotKeyRegistrar(),
            supportDirectory: temporarySupportDirectory(),
            libraryPersistence: persistence
        )

        async let first: Void = model.start()
        async let second: Void = model.start()
        _ = await (first, second)

        XCTAssertTrue(model.isReady)
        let loadCount = await persistence.loadCount()
        XCTAssertEqual(loadCount, 1)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "ClipboardRouterAppTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw XCTSkip("Could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func temporarySupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterAppTests-\(UUID().uuidString)")
    }
}

@MainActor
private final class FakeMenuBarContinuationPresenter: MenuBarContinuationPresenting {
    private(set) var presentCallCount = 0
    private(set) var dismissCallCount = 0
    private(set) var hasActiveRequest = false

    func present(_ action: MenuBarContinuationRequest.Action) -> Bool {
        presentCallCount += 1
        guard !hasActiveRequest else { return false }
        hasActiveRequest = true
        return true
    }

    func dismiss() {
        dismissCallCount += 1
        hasActiveRequest = false
    }
}

private actor CountingClipboardLibraryStore: ClipboardLibraryPersisting {
    private var loads = 0
    private var snapshot = ClipboardLibrarySnapshot.empty

    func load() async throws -> ClipboardLibrarySnapshot {
        loads += 1
        try await Task.sleep(for: .milliseconds(50))
        return snapshot
    }

    func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        self.snapshot = snapshot
    }

    func loadCount() -> Int { loads }
}

private actor FakeHostedAssistantClient: HostedAssistantResponding {
    private(set) var callCount = 0
    private(set) var lastRequest: HostedAssistantRequest?

    func respond(
        to request: HostedAssistantRequest,
        apiKey: String
    ) async throws -> HostedAssistantResponse {
        callCount += 1
        lastRequest = request
        return HostedAssistantResponse(model: request.model, text: "draft")
    }
}

@MainActor
private final class FakeLocalAIProcessor: ClipAIProcessing {
    let availability: OnDeviceAIAvailability
    private let response: String

    init(
        response: String,
        availability: OnDeviceAIAvailability = .available
    ) {
        self.response = response
        self.availability = availability
    }

    func respond(context: String, prompt: String) async throws -> String {
        response
    }
}

private final class FakeHostedCredentialStore: HostedAssistantCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var apiKey: String?

    init(apiKey: String?) { self.apiKey = apiKey }

    func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        lock.lock()
        self.apiKey = apiKey
        lock.unlock()
    }

    func deleteAPIKey() throws {
        lock.lock()
        apiKey = nil
        lock.unlock()
    }
}

@MainActor
private final class FakeHotKeyRegistrar: GlobalHotKeyRegistering {
    private let failingDescriptor: GlobalHotKeyDescriptor?
    private(set) var registeredDescriptors: [GlobalHotKeyDescriptor] = []

    init(failingDescriptor: GlobalHotKeyDescriptor? = nil) {
        self.failingDescriptor = failingDescriptor
    }

    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {
        registeredDescriptors.append(descriptor)
        if descriptor == failingDescriptor {
            throw FakeRegistrationError.conflict
        }
    }

    func unregister() {}
}

private enum FakeRegistrationError: Error {
    case conflict
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var state: LaunchAtLoginState
    private let stateAfterRegistration: LaunchAtLoginState
    private var registrationError: FakeLaunchAtLoginError?
    private let unregistrationError: FakeLaunchAtLoginError?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        state: LaunchAtLoginState,
        stateAfterRegistration: LaunchAtLoginState = .on,
        registrationError: FakeLaunchAtLoginError? = nil,
        unregistrationError: FakeLaunchAtLoginError? = nil
    ) {
        self.state = state
        self.stateAfterRegistration = stateAfterRegistration
        self.registrationError = registrationError
        self.unregistrationError = unregistrationError
    }

    func register() throws {
        registerCallCount += 1
        if let registrationError { throw registrationError }
        state = stateAfterRegistration
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregistrationError { throw unregistrationError }
        state = .off
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }

    func simulateExternalStateChange(to state: LaunchAtLoginState) {
        self.state = state
    }

    func simulateRegistrationError(_ error: FakeLaunchAtLoginError?) {
        registrationError = error
    }
}

private enum FakeLaunchAtLoginError: LocalizedError {
    case failure

    var errorDescription: String? { "Registration failed" }
}
