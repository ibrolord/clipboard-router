import AppKit
import CryptoKit
import SwiftUI
import Vision
import XCTest
@testable import ClipboardRouterApp

private final class SettingsVisualWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Native visual regression coverage for the complete Settings information architecture.
///
/// This test renders the production `SettingsView` through `NSHostingView`; it does not replace
/// the UI with a test double. Set `CLIPBOARD_ROUTER_SETTINGS_EVIDENCE_DIR` to persist the PNG
/// matrix and JSON manifest. Without it, the same acceptance checks run in a temporary folder.
@MainActor
final class SettingsVisualAcceptanceTests: XCTestCase {
    private struct Viewport: Codable, Equatable {
        let width: Int
        let height: Int

        var size: CGSize { CGSize(width: width, height: height) }
        var slug: String { "\(width)x\(height)" }
    }

    private struct Scenario {
        let tab: SettingsTab
        let viewport: Viewport
        let menuBarClipLimit: Int
        let fileStem: String
        let requiredAccessibilityValues: [String]
    }

    private struct Evidence: Codable {
        let file: String
        let tab: String
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let menuBarClipLimit: Int
        let splitPaneCount: Int
        let scrollViewCount: Int
        let detailContentWidth: Double
        let sampledColorCount: Int
        let sha256: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let renderedAt: String
        let appearance: String
        let maximumDetailContentWidth: Double
        let scenarios: [Evidence]
    }

    private let viewports = [
        Viewport(width: 680, height: 560),
        Viewport(width: 760, height: 640),
        Viewport(width: 960, height: 720),
    ]

    func testRenderAllVisibleSettingsTabsAndClipCountStates() throws {
        let outputDirectory = try evidenceDirectory()
        let scenarios = matrixScenarios() + clipCountScenarios()
        XCTAssertEqual(scenarios.count, 24)

        var evidence: [Evidence] = []
        for scenario in scenarios {
            evidence.append(try render(scenario, into: outputDirectory))
        }

        for viewport in viewports {
            let hashes = Set(evidence.filter {
                $0.logicalWidth == viewport.width
                    && $0.logicalHeight == viewport.height
                    && $0.file.hasPrefix("settings-")
                    && !$0.file.contains("-count-")
            }.map(\.sha256))
            XCTAssertEqual(
                hashes.count,
                SettingsTab.visibleCases.count,
                "Every Settings destination must render a visibly distinct pane at \(viewport.slug)"
            )
        }
        let countHashes = Set(evidence.filter { $0.file.contains("-count-") }.map(\.sha256))
        XCTAssertEqual(countHashes.count, 3, "The 1, 100, and 1,000 count states must render distinctly")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = Manifest(
            schemaVersion: 1,
            renderedAt: formatter.string(from: Date()),
            appearance: "NSAppearance.Name.darkAqua",
            maximumDetailContentWidth: SettingsLayout.maximumDetailContentWidth,
            scenarios: evidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: outputDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func matrixScenarios() -> [Scenario] {
        let anchors: [SettingsTab: [String]] = [
            .general: ["30 days", "⌘⇧V"],
            .destinations: ["ChatGPT"],
            .assistant: ["gpt-5-nano", "Not configured"],
            .crm: ["Salesforce"],
            .sync: ["Not configured — polling only", "Verified"],
            .license: ["Device"],
            .privacy: ["45 seconds", "Off"],
        ]

        return viewports.flatMap { viewport in
            SettingsTab.visibleCases.map { tab in
                Scenario(
                    tab: tab,
                    viewport: viewport,
                    menuBarClipLimit: 100,
                    fileStem: "settings-\(slug(tab))-\(viewport.slug)",
                    requiredAccessibilityValues: anchors[tab]!
                )
            }
        }
    }

    private func clipCountScenarios() -> [Scenario] {
        [1, 100, 1_000].map { count in
            Scenario(
                tab: .general,
                viewport: Viewport(width: 760, height: 640),
                menuBarClipLimit: count,
                fileStem: "settings-general-count-\(count)-760x640",
                requiredAccessibilityValues: ["\(count)", "stepper"]
            )
        }
    }

    private func render(_ scenario: Scenario, into outputDirectory: URL) throws -> Evidence {
        let suiteName = "com.clipboardrouter.settings-visual.\(scenario.fileStem)"
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterSettingsVisual", isDirectory: true)
            .appendingPathComponent(scenario.fileStem, isDirectory: true)
        let configuration = UIAcceptanceRuntime.Configuration(
            runID: scenario.fileStem,
            defaultsSuiteName: suiteName,
            supportDirectory: supportDirectory
        )
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Could not create isolated Settings defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(scenario.tab.rawValue, forKey: "settings.selectedTab")
        guard let model = UIAcceptanceRuntime.makeModel(
            configuration: configuration,
            menuBarClipLimit: scenario.menuBarClipLimit
        ) else {
            XCTFail("Could not build isolated Settings model")
            throw CocoaError(.coderInvalidValue)
        }
        // `makeModel` resets its suite, so select the requested tab after model construction.
        defaults.set(scenario.tab.rawValue, forKey: "settings.selectedTab")

        let root = SettingsView(
            model: model,
            defaults: defaults,
            performsLiveRefreshes: false
        )
        .frame(width: scenario.viewport.size.width, height: scenario.viewport.size.height)
        .environment(\.colorScheme, .dark)
        .tint(.blue)

        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: scenario.viewport.size)

        let window = SettingsVisualWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.title = "Clipboard Router Settings Visual"
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.bounds.size.width, scenario.viewport.size.width, accuracy: 0.01)
        XCTAssertEqual(hostingView.bounds.size.height, scenario.viewport.size.height, accuracy: 0.01)

        let allViews = descendants(of: hostingView)
        let splitViews = allViews.compactMap { $0 as? NSSplitView }
        guard let primarySplit = splitViews.max(by: { $0.subviews.count < $1.subviews.count }) else {
            XCTFail("Settings did not render a native split view for \(scenario.fileStem)")
            throw CocoaError(.coderInvalidValue)
        }
        try assertSplitLayout(primarySplit, inside: hostingView, scenario: scenario)

        let scrollViews = allViews.compactMap { $0 as? NSScrollView }.filter { !$0.isHidden }
        XCTAssertGreaterThanOrEqual(
            scrollViews.count,
            2,
            "Sidebar and detail must remain independently scrollable in \(scenario.fileStem)"
        )
        XCTAssertTrue(
            scrollViews.contains(where: \.hasVerticalScroller),
            "Settings detail must retain a vertical scroll affordance in \(scenario.fileStem)"
        )

        guard let detailProbe = allViews.compactMap({ $0 as? SettingsDetailWidthProbeView }).first else {
            XCTFail("Settings detail width probe did not render")
            throw CocoaError(.coderInvalidValue)
        }
        let detailFrame = detailProbe.convert(detailProbe.bounds, to: hostingView)
        XCTAssertGreaterThan(detailFrame.width, 280)
        XCTAssertLessThanOrEqual(
            detailFrame.width,
            SettingsLayout.maximumDetailContentWidth + 1,
            "Wide Settings content must stay within the 760 pt reading measure"
        )
        XCTAssertTrue(
            hostingView.bounds.insetBy(dx: -1, dy: -1).contains(detailFrame),
            "The bounded Settings detail is clipped outside the window"
        )
        if scenario.viewport.width == 960 {
            XCTAssertEqual(
                detailFrame.width,
                SettingsLayout.maximumDetailContentWidth,
                accuracy: 1,
                "The 960 pt window should resolve the intended readable detail width"
            )
        }

        let accessibilityText = accessibilitySnapshot(from: hostingView)
        for requiredText in scenario.requiredAccessibilityValues {
            XCTAssertTrue(
                accessibilityText.localizedCaseInsensitiveContains(requiredText),
                "Missing native control/value anchor ‘\(requiredText)’ in \(scenario.fileStem)"
            )
        }
        if scenario.tab == .general {
            XCTAssertEqual(model.menuBarClipLimit, scenario.menuBarClipLimit)
            XCTAssertTrue(accessibilityText.localizedCaseInsensitiveContains("stepper"))
        }

        let bitmap = try bitmapImage(of: hostingView, normalizedTo: scenario.viewport.size)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(scenario.fileStem) as PNG")
            throw CocoaError(.fileWriteUnknown)
        }
        let imageURL = outputDirectory.appendingPathComponent("\(scenario.fileStem).png")
        try png.write(to: imageURL, options: .atomic)
        try assertRenderedSidebar(in: bitmap, selectedTab: scenario.tab, scenario: scenario)
        let sampledColorCount = sampledColors(in: bitmap)
        XCTAssertGreaterThan(
            sampledColorCount,
            80,
            "Rendered Settings image is blank or visually incomplete: \(scenario.fileStem)"
        )
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: suiteName)

        return Evidence(
            file: imageURL.lastPathComponent,
            tab: scenario.tab.rawValue,
            logicalWidth: scenario.viewport.width,
            logicalHeight: scenario.viewport.height,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            menuBarClipLimit: scenario.menuBarClipLimit,
            splitPaneCount: primarySplit.subviews.count,
            scrollViewCount: scrollViews.count,
            detailContentWidth: detailFrame.width,
            sampledColorCount: sampledColorCount,
            sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func assertSplitLayout(
        _ splitView: NSSplitView,
        inside hostingView: NSView,
        scenario: Scenario
    ) throws {
        let splitFrame = splitView.convert(splitView.bounds, to: hostingView)
        let permittedBounds = hostingView.bounds.insetBy(dx: -1, dy: -1)
        XCTAssertTrue(permittedBounds.contains(splitFrame))

        // NavigationSplitView intentionally layers the sidebar over a full-width detail wrapper.
        // Validate each system wrapper remains in bounds and that the resolved sidebar stays
        // within the production 176...220 pt contract instead of treating that native layering
        // as a content collision.
        let wrappers = splitView.subviews.filter {
            String(describing: type(of: $0)).contains("SplitViewItemViewWrapper")
        }
        XCTAssertGreaterThanOrEqual(wrappers.count, 2)
        let convertedFrames = wrappers.map { $0.convert($0.bounds, to: hostingView) }
        for frame in convertedFrames {
            XCTAssertTrue(
                permittedBounds.contains(frame),
                "A Settings pane is clipped outside \(scenario.fileStem): \(frame)"
            )
        }
        guard let sidebarFrame = convertedFrames.min(by: { $0.width < $1.width }) else { return }
        XCTAssertGreaterThanOrEqual(sidebarFrame.width, 176)
        XCTAssertLessThanOrEqual(sidebarFrame.width, 220)
    }

    private func bitmapImage(of view: NSView, normalizedTo size: CGSize) throws -> NSBitmapImageRep {
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
        try compositeNativeSidebar(in: view, onto: bitmap)
        return bitmap
    }

    private func compositeNativeSidebar(in root: NSView, onto bitmap: NSBitmapImageRep) throws {
        let allViews = descendants(of: root)
        guard let splitView = allViews.compactMap({ $0 as? NSSplitView }).first,
              let sidebarWrapper = splitView.subviews
                  .filter({ String(describing: type(of: $0)).contains("SplitViewItemViewWrapper") })
                  .min(by: { $0.bounds.width < $1.bounds.width }),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            throw CocoaError(.coderInvalidValue)
        }

        let sidebarFrame = sidebarWrapper.convert(sidebarWrapper.bounds, to: root)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            sidebarFrame.fill()
        }

        let rowViews = descendants(of: sidebarWrapper).filter {
            String(describing: type(of: $0)).contains("ListTableRowView") && !$0.isHidden
        }
        for rowView in rowViews {
            let rowFrame = rowView.convert(rowView.bounds, to: root)
            let bitmapFrame = NSRect(
                x: rowFrame.minX,
                y: root.bounds.height - rowFrame.maxY,
                width: rowFrame.width,
                height: rowFrame.height
            )
            guard sidebarFrame.intersects(rowFrame),
                  let rowBitmap = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds)
            else { continue }
            rowView.effectiveAppearance.performAsCurrentDrawingAppearance {
                rowView.cacheDisplay(in: rowView.bounds, to: rowBitmap)
            }
            let image = NSImage(size: rowView.bounds.size)
            image.addRepresentation(rowBitmap)
            image.draw(
                in: bitmapFrame,
                from: rowView.bounds,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func sampledColors(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        let step = 8
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
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

    private func assertRenderedSidebar(
        in bitmap: NSBitmapImageRep,
        selectedTab: SettingsTab,
        scenario: Scenario
    ) throws {
        let sidebarWidth = min(198, bitmap.pixelsWide)
        var nearWhitePixels = 0
        var sampledPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: sidebarWidth, by: 6) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampledPixels += 1
                if color.redComponent > 0.92,
                   color.greenComponent > 0.92,
                   color.blueComponent > 0.92
                {
                    nearWhitePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(sampledPixels, 0)
        let nearWhiteRatio = Double(nearWhitePixels) / Double(max(sampledPixels, 1))
        guard nearWhiteRatio < 0.15 else {
            XCTFail("The dark Settings sidebar rendered blank/white in \(scenario.fileStem)")
            throw CocoaError(.coderInvalidValue)
        }

        guard let fullImage = bitmap.cgImage,
              let sidebarImage = fullImage.cropping(to: CGRect(
                  x: 0,
                  y: 0,
                  width: sidebarWidth,
                  height: bitmap.pixelsHigh
              ))
        else {
            XCTFail("Could not crop the Settings sidebar for \(scenario.fileStem)")
            return
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: sidebarImage, orientation: .up)
        try handler.perform([request])
        let observations = request.results ?? []
        let recognized = observations.compactMap { $0.topCandidates(1).first?.string }
        let normalizedOCR = normalizedOCRString(recognized.joined(separator: " "))
        for tab in SettingsTab.visibleCases {
            guard normalizedOCR.contains(tab.rawValue.lowercased()) else {
                XCTFail(
                    "Sidebar label ‘\(tab.rawValue)’ is not visibly rendered in \(scenario.fileStem). OCR: \(recognized)"
                )
                throw CocoaError(.coderInvalidValue)
            }
        }

        guard let selectedObservation = observations.first(where: {
            guard let candidate = $0.topCandidates(1).first?.string else { return false }
            return normalizedOCRString(candidate)
                .contains(selectedTab.rawValue.lowercased())
        }) else {
            XCTFail("Could not locate selected sidebar label ‘\(selectedTab.rawValue)’ in \(scenario.fileStem)")
            return
        }
        let centerY = Int(selectedObservation.boundingBox.midY * Double(bitmap.pixelsHigh))
        let reflectedCenterY = bitmap.pixelsHigh - centerY
        let highlightCount = max(
            selectedRowHighlightPixelCount(in: bitmap, sidebarWidth: sidebarWidth, centerY: centerY),
            selectedRowHighlightPixelCount(
                in: bitmap,
                sidebarWidth: sidebarWidth,
                centerY: reflectedCenterY
            )
        )
        XCTAssertGreaterThan(
            highlightCount,
            sidebarWidth,
            "Selected tab ‘\(selectedTab.rawValue)’ lacks a visible highlight row in \(scenario.fileStem)"
        )
    }

    private func normalizedOCRString(_ text: String) -> String {
        let padded = " \(text.lowercased()) "
            // Vision commonly reads the sans-serif capital I in “AI” as a lowercase L,
            // and can drop the leading lowercase i in the iCloud wordmark.
            .replacingOccurrences(of: "al assistant", with: "ai assistant")
            .replacingOccurrences(of: " cloud ", with: " icloud ")
        return padded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedRowHighlightPixelCount(
        in bitmap: NSBitmapImageRep,
        sidebarWidth: Int,
        centerY: Int
    ) -> Int {
        var count = 0
        for y in max(0, centerY - 13)...min(bitmap.pixelsHigh - 1, centerY + 13) {
            for x in 4..<max(5, sidebarWidth - 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                let luminance = color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
                let blueAccent = color.blueComponent > 0.42
                    && color.blueComponent > color.redComponent * 1.18
                    && color.blueComponent > color.greenComponent * 1.04
                let inactiveNeutralHighlight = (0.18...0.55).contains(luminance)
                    && maximum - minimum < 0.1
                if blueAccent || inactiveNeutralHighlight {
                    count += 1
                }
            }
        }
        return count
    }

    private func accessibilitySnapshot(from view: NSView) -> String {
        var components: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ value: Any, depth: Int) {
            guard depth < 40, let object = value as? NSObject else { return }
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }

            if object is NSAccessibilityElementProtocol {
                let stringSelectors = [
                    "accessibilityIdentifier",
                    "accessibilityLabel",
                    "accessibilityTitle",
                    "accessibilityValue",
                    "accessibilityHelp",
                    "accessibilityRoleDescription",
                ]
                for selectorName in stringSelectors {
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

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func drainMainRunLoop() {
        let deadline = Date().addingTimeInterval(0.12)
        while RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}
    }

    private func evidenceDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let requested = environment["CLIPBOARD_ROUTER_SETTINGS_EVIDENCE_DIR"],
           !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            url = URL(fileURLWithPath: requested, isDirectory: true)
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardRouterSettingsVisualEvidence", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func slug(_ tab: SettingsTab) -> String {
        tab.rawValue.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "icloud", with: "icloud")
    }
}
