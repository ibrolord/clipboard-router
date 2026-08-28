import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import CryptoKit
import SwiftUI
import XCTest
@testable import ClipboardRouterApp

/// App-only visual evidence for the production menu, Library, and key continuation surfaces.
///
/// The renderer snapshots `NSHostingView` directly. It never asks macOS for a desktop or window
/// capture, so Screen Recording permission and unrelated windows cannot contaminate the evidence.
/// Set `CLIPBOARD_ROUTER_SURFACE_EVIDENCE_DIR` to persist the PNGs, JSON manifest, and SHA-256
/// checksum file. Without it, the same layout assertions run in a temporary directory.
@MainActor
final class SurfaceVisualEvidenceTests: XCTestCase {
    private struct Viewport: Codable, Equatable {
        let width: Int
        let height: Int

        var size: CGSize { CGSize(width: width, height: height) }
        var slug: String { "\(width)x\(height)" }
    }

    private struct Scenario {
        enum Inspection {
            case menuBar
            case library
            case editor
            case assistant
        }

        let name: String
        let viewport: Viewport
        let requiredAccessibilityAnchors: [String]
        let build: @MainActor (AppModel) -> AnyView
        let inspection: Inspection
    }

    private struct Evidence: Codable {
        let surface: String
        let file: String
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let sampledColorCount: Int
        let nontransparentPixelRatio: Double
        let visibleNativeViewCount: Int
        let accessibilityAnchorCount: Int
        let geometry: [String: Double]
        let sha256: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let renderedAt: String
        let renderer: String
        let appearance: String
        let fixtureHistoryCount: Int
        let scenarios: [Evidence]
    }

    func testRenderProductionSurfaceEvidence() async throws {
        let outputDirectory = try evidenceDirectory()
        let model = try await makeReadyModel(outputDirectory: outputDirectory)
        guard let selectedClip = model.clipsForSelectedSection.first else {
            XCTFail("UI acceptance fixture did not expose a History clip")
            return
        }
        model.setSelectedClipIDs([selectedClip.id])

        let scenarios = makeScenarios(selectedClip: selectedClip)
        XCTAssertEqual(scenarios.count, 6)

        var evidence: [Evidence] = []
        for scenario in scenarios {
            evidence.append(try render(scenario, model: model, into: outputDirectory))
        }

        let hashes = Set(evidence.map(\.sha256))
        XCTAssertEqual(
            hashes.count,
            scenarios.count,
            "Every production surface and viewport must produce distinct visual evidence"
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = Manifest(
            schemaVersion: 1,
            renderedAt: formatter.string(from: Date()),
            renderer: "NSHostingView.cacheDisplay (app-only; no desktop capture)",
            appearance: "NSAppearance.Name.darkAqua",
            fixtureHistoryCount: UIAcceptanceRuntime.fixtureHistoryCount,
            scenarios: evidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        let checksumEntries = evidence.map { "\($0.sha256)  \($0.file)" } + [
            "\(sha256(manifestData))  \(manifestURL.lastPathComponent)"
        ]
        try (checksumEntries.joined(separator: "\n") + "\n").write(
            to: outputDirectory.appendingPathComponent("sha256.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeReadyModel(outputDirectory: URL) async throws -> AppModel {
        let runID = "surface-visual-evidence"
        let suiteName = "com.clipboardrouter.surface-visual-evidence"
        let configuration = UIAcceptanceRuntime.Configuration(
            runID: runID,
            defaultsSuiteName: suiteName,
            supportDirectory: outputDirectory.appendingPathComponent("runtime", isDirectory: true)
        )
        guard let model = UIAcceptanceRuntime.makeModel(
            configuration: configuration,
            menuBarClipLimit: 100
        ) else {
            XCTFail("Could not create deterministic UI acceptance model")
            throw CocoaError(.coderInvalidValue)
        }
        await model.start()
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.snapshot.history.count, UIAcceptanceRuntime.fixtureHistoryCount)
        return model
    }

    private func makeScenarios(selectedClip: PresentedClip) -> [Scenario] {
        [
            Scenario(
                name: "menu-bar",
                viewport: Viewport(width: 420, height: 500),
                requiredAccessibilityAnchors: ["Search clips", "No Active Project"],
                build: { model in AnyView(MenuBarView(model: model)) },
                inspection: .menuBar
            ),
            Scenario(
                name: "library-minimum",
                viewport: Viewport(width: 900, height: 590),
                requiredAccessibilityAnchors: [selectedClip.title],
                build: { model in AnyView(MainWindowView(model: model)) },
                inspection: .library
            ),
            Scenario(
                name: "library-normal",
                viewport: Viewport(width: 1_080, height: 700),
                requiredAccessibilityAnchors: [selectedClip.title],
                build: { model in AnyView(MainWindowView(model: model)) },
                inspection: .library
            ),
            Scenario(
                name: "continuation-make-note",
                viewport: Viewport(width: 560, height: 470),
                requiredAccessibilityAnchors: [selectedClip.title],
                build: { model in
                    AnyView(
                        MenuBarContinuationSheet(
                            model: model,
                            request: MenuBarContinuationRequest(
                                action: .noteEditor(
                                    NoteEditorRequest(mode: .makeFromClip(selectedClip))
                                )
                            )
                        )
                    )
                },
                inspection: .editor
            ),
            Scenario(
                name: "continuation-edit-clip",
                viewport: Viewport(width: 560, height: 500),
                requiredAccessibilityAnchors: ["Clip name", selectedClip.title],
                build: { model in
                    AnyView(
                        MenuBarContinuationSheet(
                            model: model,
                            request: MenuBarContinuationRequest(
                                action: .clipEditor(
                                    ClipEditorRequest(mode: .editHistoryCopy(selectedClip))
                                )
                            )
                        )
                    )
                },
                inspection: .editor
            ),
            Scenario(
                name: "continuation-ai",
                viewport: Viewport(width: 600, height: 260),
                requiredAccessibilityAnchors: [],
                build: { model in
                    AnyView(
                        AIClipAssistantSheet(
                            availability: .appleIntelligenceUnavailable,
                            cloudConfigured: false,
                            cloudConsentGranted: false,
                            cloudModel: "gpt-5-nano",
                            cloudSourceEligible: true,
                            cloudSourceUnavailableReason: "",
                            sourceTitle: selectedClip.title,
                            ask: { _, _, _, _ in nil },
                            saveResult: { _, _ in false },
                            copyResult: { _ in },
                            errorMessage: Binding(
                                get: { model.errorMessage },
                                set: { model.errorMessage = $0 }
                            ),
                            cancel: {}
                        )
                    )
                },
                inspection: .assistant
            ),
        ]
    }

    private func render(
        _ scenario: Scenario,
        model: AppModel,
        into outputDirectory: URL
    ) throws -> Evidence {
        let root = scenario.build(model)
            .frame(width: scenario.viewport.size.width, height: scenario.viewport.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: scenario.viewport.size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 160, y: 160), size: scenario.viewport.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        settle(window: window, hostingView: hostingView)

        XCTAssertEqual(hostingView.bounds.width, scenario.viewport.size.width, accuracy: 0.01)
        XCTAssertEqual(hostingView.bounds.height, scenario.viewport.size.height, accuracy: 0.01)

        let allViews = descendants(of: hostingView)
        let visibleViews = allViews.filter {
            !$0.isHidden && $0.alphaValue > 0.01 && $0.bounds.width > 1 && $0.bounds.height > 1
                && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }
        XCTAssertGreaterThan(visibleViews.count, 10, "Production surface did not lay out native views")

        let accessibilityText = accessibilitySnapshot(from: hostingView)
            + " | " + nativeControlSnapshot(from: hostingView)
        for anchor in scenario.requiredAccessibilityAnchors {
            XCTAssertTrue(
                accessibilityText.localizedCaseInsensitiveContains(anchor),
                "Missing accessibility anchor ‘\(anchor)’ in \(scenario.name)"
            )
        }

        let geometry: [String: Double]
        switch scenario.inspection {
        case .menuBar:
            geometry = try inspectMenuBar(hostingView)
        case .library:
            geometry = try inspectLibrary(hostingView)
        case .editor:
            geometry = try inspectEditor(hostingView)
        case .assistant:
            geometry = try inspectAssistant(hostingView)
        }
        let bitmap = try bitmapImage(of: hostingView, size: scenario.viewport.size)
        let sampledColorCount = sampledColors(in: bitmap)
        let nontransparentPixelRatio = nontransparentRatio(in: bitmap)
        XCTAssertGreaterThan(sampledColorCount, 10, "\(scenario.name) rendered blank or incomplete")
        XCTAssertGreaterThan(nontransparentPixelRatio, 0.85, "\(scenario.name) left most pixels blank")
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(scenario.name) PNG")
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = "\(scenario.name)-\(scenario.viewport.slug).png"
        let imageURL = outputDirectory.appendingPathComponent(fileName)
        try png.write(to: imageURL, options: .atomic)

        window.contentView = nil
        window.close()

        return Evidence(
            surface: scenario.name,
            file: fileName,
            logicalWidth: scenario.viewport.width,
            logicalHeight: scenario.viewport.height,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            sampledColorCount: sampledColorCount,
            nontransparentPixelRatio: nontransparentPixelRatio,
            visibleNativeViewCount: visibleViews.count,
            accessibilityAnchorCount: scenario.requiredAccessibilityAnchors.count
                + Int(geometry["nativeAccessibilityAnchorCount"] ?? 0),
            geometry: geometry,
            sha256: sha256(png)
        )
    }

    private func inspectMenuBar(_ hostingView: NSHostingView<AnyView>) throws -> [String: Double] {
        let views = descendants(of: hostingView)
        guard let search = views.compactMap({ $0 as? NSTextField }).first(where: {
            $0.placeholderString == "Search clips"
        }), let scrollView = views.compactMap({ $0 as? NSScrollView }).first(where: {
            !$0.isHidden && $0.hasVerticalScroller
        }) else {
            XCTFail("Menu bar search field or clip scroll view did not render")
            throw CocoaError(.coderInvalidValue)
        }
        let searchFrame = search.convert(search.bounds, to: hostingView)
        let scrollFrame = scrollView.convert(scrollView.bounds, to: hostingView)
        assertContained(searchFrame, in: hostingView.bounds, label: "Menu search")
        assertContained(scrollFrame, in: hostingView.bounds, label: "Menu clip list")
        XCTAssertFalse(
            searchFrame.insetBy(dx: 0, dy: 1).intersects(scrollFrame.insetBy(dx: 0, dy: 1)),
            "Menu search overlaps the clip list"
        )
        XCTAssertGreaterThanOrEqual(scrollFrame.height, MenuBarLayoutMetrics.clipListMinimumHeight - 2)
        return [
            "searchWidth": searchFrame.width,
            "clipListHeight": scrollFrame.height,
            "clipListMinimumHeight": MenuBarLayoutMetrics.clipListMinimumHeight,
            "nativeAccessibilityAnchorCount": 2,
        ]
    }

    private func inspectLibrary(_ hostingView: NSHostingView<AnyView>) throws -> [String: Double] {
        let splitViews = descendants(of: hostingView).compactMap { $0 as? NSSplitView }
            .filter { !$0.isHidden && $0.alphaValue > 0.01 }
        XCTAssertGreaterThanOrEqual(splitViews.count, 1, "Library content split did not render")
        for splitView in splitViews {
            let splitFrame = splitView.convert(splitView.bounds, to: hostingView)
            guard splitFrame.intersects(hostingView.bounds), splitFrame.width > 100 else { continue }
            assertContained(splitFrame, in: hostingView.bounds, label: "Library split")
            let paneFrames = splitView.subviews.filter { !$0.isHidden }.map {
                $0.convert($0.bounds, to: hostingView)
            }.filter { $0.width > 1 && $0.height > 1 }
            for paneFrame in paneFrames {
                assertContained(paneFrame, in: hostingView.bounds, label: "Library pane")
            }
            let ordered = paneFrames.sorted { $0.minX < $1.minX }
            for pair in zip(ordered, ordered.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    pair.0.maxX,
                    pair.1.minX + splitView.dividerThickness + 2,
                    "Adjacent Library panes overlap"
                )
            }
        }
        let scrollViews = descendants(of: hostingView).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHidden && $0.alphaValue > 0.01
                && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }
        XCTAssertGreaterThanOrEqual(scrollViews.count, 3)
        return [
            "splitViewCount": Double(splitViews.count),
            "scrollViewCount": Double(scrollViews.count),
            "sidebarContractWidth": 240,
            "nativeAccessibilityAnchorCount": 1,
        ]
    }

    private func inspectEditor(_ hostingView: NSHostingView<AnyView>) throws -> [String: Double] {
        let views = descendants(of: hostingView)
        let textFields = views.compactMap { $0 as? NSTextField }.filter {
            !$0.isHidden && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }
        let textViews = views.compactMap { $0 as? NSTextView }.filter {
            !$0.isHidden && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }
        guard let titleField = textFields.max(by: {
            $0.convert($0.bounds, to: hostingView).minY
                < $1.convert($1.bounds, to: hostingView).minY
        }), let body = textViews.max(by: {
            $0.convert($0.bounds, to: hostingView).height
                < $1.convert($1.bounds, to: hostingView).height
        }) else {
            XCTFail("Continuation editor controls did not render")
            throw CocoaError(.coderInvalidValue)
        }
        let titleFrame = titleField.convert(titleField.bounds, to: hostingView)
        let bodyFrame = body.convert(body.bounds, to: hostingView)
        assertContained(titleFrame, in: hostingView.bounds, label: "Editor title")
        assertContained(bodyFrame, in: hostingView.bounds, label: "Editor body")
        XCTAssertFalse(
            titleFrame.insetBy(dx: 0, dy: 1).intersects(bodyFrame.insetBy(dx: 0, dy: 1)),
            "Editor title overlaps body"
        )
        XCTAssertGreaterThan(bodyFrame.height, 180)
        return [
            "titleWidth": titleFrame.width,
            "bodyHeight": bodyFrame.height,
            "nativeAccessibilityAnchorCount": 2,
        ]
    }

    private func inspectAssistant(_ hostingView: NSHostingView<AnyView>) throws -> [String: Double] {
        let views = descendants(of: hostingView)
        guard let composer = views.compactMap({ $0 as? NSTextView }).first(where: {
            !$0.isHidden && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }), let processingMode = views.compactMap({ $0 as? NSSegmentedControl }).first(where: {
            !$0.isHidden && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }) else {
            XCTFail("Assistant composer or processing mode did not render")
            throw CocoaError(.coderInvalidValue)
        }
        let composerFrame = composer.convert(composer.bounds, to: hostingView)
        let modeFrame = processingMode.convert(processingMode.bounds, to: hostingView)
        assertContained(composerFrame, in: hostingView.bounds, label: "Assistant composer")
        assertContained(modeFrame, in: hostingView.bounds, label: "Assistant processing mode")
        XCTAssertFalse(
            modeFrame.insetBy(dx: 0, dy: 1).intersects(composerFrame.insetBy(dx: 0, dy: 1)),
            "Assistant processing mode overlaps the prompt composer"
        )
        XCTAssertGreaterThan(composerFrame.height, 40)
        return [
            "composerHeight": composerFrame.height,
            "processingModeWidth": modeFrame.width,
            "nativeAccessibilityAnchorCount": 2,
        ]
    }

    private func assertContained(
        _ frame: CGRect,
        in bounds: CGRect,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            bounds.insetBy(dx: -1, dy: -1).contains(frame),
            "\(label) is clipped: \(frame) outside \(bounds)",
            file: file,
            line: line
        )
    }

    private func settle(window: NSWindow, hostingView: NSHostingView<AnyView>) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(0.08)
            while RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}
        }
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func bitmapImage(of view: NSView, size: CGSize) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func sampledColors(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.insert((red << 16) | (green << 8) | blue)
            }
        }
        return colors.count
    }

    private func nontransparentRatio(in bitmap: NSBitmapImageRep) -> Double {
        var opaqueSamples = 0
        var allSamples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                allSamples += 1
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    opaqueSamples += 1
                }
            }
        }
        return allSamples == 0 ? 0 : Double(opaqueSamples) / Double(allSamples)
    }

    private func accessibilitySnapshot(from view: NSView) -> String {
        var components: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ value: Any, depth: Int) {
            guard depth < 40, let object = value as? NSObject else { return }
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }

            if object is NSAccessibilityElementProtocol {
                for selectorName in [
                    "accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle",
                    "accessibilityValue", "accessibilityHelp", "accessibilityRoleDescription",
                ] {
                    let selector = NSSelectorFromString(selectorName)
                    guard object.responds(to: selector),
                          let value = object.perform(selector)?.takeUnretainedValue()
                    else { continue }
                    if let string = value as? String { components.append(string) }
                    else if let number = value as? NSNumber { components.append(number.stringValue) }
                }
                let childrenSelector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: childrenSelector),
                   let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any]
                {
                    children.forEach { visit($0, depth: depth + 1) }
                }
            }
            if let view = object as? NSView {
                view.subviews.forEach { visit($0, depth: depth + 1) }
            }
        }

        visit(view, depth: 0)
        return components.joined(separator: " | ")
    }

    private func nativeControlSnapshot(from view: NSView) -> String {
        descendants(of: view).flatMap { candidate -> [String] in
            var values: [String] = []
            if let control = candidate as? NSControl {
                if !control.stringValue.isEmpty { values.append(control.stringValue) }
                if let identifier = control.identifier?.rawValue { values.append(identifier) }
            }
            if let field = candidate as? NSTextField, let placeholder = field.placeholderString {
                values.append(placeholder)
            }
            if let button = candidate as? NSButton, !button.title.isEmpty {
                values.append(button.title)
            }
            if let segmented = candidate as? NSSegmentedControl {
                for index in 0..<segmented.segmentCount {
                    if let label = segmented.label(forSegment: index), !label.isEmpty {
                        values.append(label)
                    }
                }
            }
            return values
        }.joined(separator: " | ")
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func evidenceDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let requested = environment["CLIPBOARD_ROUTER_SURFACE_EVIDENCE_DIR"],
           !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            url = URL(fileURLWithPath: requested, isDirectory: true)
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardRouterSurfaceVisualEvidence", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
