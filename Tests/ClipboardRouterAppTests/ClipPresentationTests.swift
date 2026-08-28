import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterApp

final class ClipPresentationTests: XCTestCase {
    func testMenuBarLayoutKeepsFourReadableRowsAndAccessibleActionTargets() {
        XCTAssertEqual(MenuBarLayoutMetrics.width, 420)
        XCTAssertEqual(MenuBarLayoutMetrics.height, 500)
        XCTAssertGreaterThanOrEqual(MenuBarLayoutMetrics.clipTitleMinimumWidth, 180)
        XCTAssertGreaterThanOrEqual(MenuBarLayoutMetrics.clipActionTarget, 28)
        XCTAssertGreaterThanOrEqual(MenuBarLayoutMetrics.clipActionSpacing, 8)
        XCTAssertGreaterThanOrEqual(MenuBarLayoutMetrics.minimumCompleteClipRows, 4)
        XCTAssertGreaterThanOrEqual(
            MenuBarLayoutMetrics.clipListMinimumHeight,
            MenuBarLayoutMetrics.clipRowHeight
                * CGFloat(MenuBarLayoutMetrics.minimumCompleteClipRows)
        )
    }

    func testClipAgeUsesMinuteGranularityWithoutASecondsCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(ClipAgeFormatter.string(since: now.addingTimeInterval(-5), relativeTo: now), "Just now")
        XCTAssertEqual(ClipAgeFormatter.string(since: now.addingTimeInterval(-65), relativeTo: now), "1 min")
        XCTAssertEqual(ClipAgeFormatter.string(since: now.addingTimeInterval(-2_405), relativeTo: now), "40 min")
        XCTAssertEqual(
            ClipAgeFormatter.string(since: now.addingTimeInterval(-4_570), relativeTo: now),
            "1 hr, 16 min"
        )
        XCTAssertEqual(ClipAgeFormatter.string(since: now.addingTimeInterval(-7_200), relativeTo: now), "2 hr")
        XCTAssertEqual(ClipAgeFormatter.string(since: now.addingTimeInterval(30), relativeTo: now), "Just now")
    }

    func testClipAgeYesterdayUsesTheSuppliedReferenceDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032,
            month: 6,
            day: 15,
            hour: 18
        )))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2032,
            month: 6,
            day: 14,
            hour: 10
        )))

        XCTAssertEqual(
            ClipAgeFormatter.string(since: yesterday, relativeTo: now, calendar: calendar),
            "Yesterday"
        )
    }

    func testStoredLinkPreviewUsesOnlyValidatedStoredMetadata() throws {
        let content = try ClipContent(
            type: .url,
            text: "https://docs.example.com/guide?q=clipboard",
            representations: ClipRepresentations(
                url: URLClipMetadata(
                    originalURL: "https://docs.example.com/guide?q=clipboard",
                    host: "untrusted.example",
                    title: "  Clipboard Guide  "
                )
            )
        )

        let descriptor = try XCTUnwrap(StoredLinkPreviewDescriptor(content: content))

        XCTAssertEqual(descriptor.title, "Clipboard Guide")
        XCTAssertEqual(descriptor.host, "docs.example.com")
        XCTAssertEqual(descriptor.displayURL, "https://docs.example.com/guide?q=clipboard")
        XCTAssertEqual(descriptor.url, URL(string: descriptor.displayURL))
    }

    func testStoredLinkPreviewFallsBackToHostAndRejectsUnsafeSchemes() throws {
        let valid = try ClipContent.detect(text: "https://example.com/path")
        XCTAssertEqual(StoredLinkPreviewDescriptor(content: valid)?.title, "example.com")

        for value in ["file:///tmp/private.txt", "javascript:alert(1)", "https:///missing-host"] {
            let content = try ClipContent(
                type: .url,
                text: value,
                representations: ClipRepresentations(
                    url: URLClipMetadata(originalURL: value)
                )
            )
            XCTAssertNil(StoredLinkPreviewDescriptor(content: content))
        }
    }

    func testMenuBarHoverPreviewUsesOnlyStoredContentAndMetadata() throws {
        let content = try ClipContent(
            type: .image,
            text: "Extracted text from the image",
            representations: ClipRepresentations(
                thumbnail: try reference(kind: .thumbnail),
                imageMetadata: try ClipImageMetadata(
                    pixelWidth: 1_920,
                    pixelHeight: 1_080,
                    format: "public.png"
                ),
                ocrText: "Extracted text from the image"
            )
        )
        let descriptor = MenuBarHoverPreviewDescriptor(clip: presentedClip(content: content))

        XCTAssertEqual(descriptor.title, "Clip title")
        XCTAssertEqual(descriptor.contentTypeName, "Image")
        XCTAssertEqual(descriptor.text, "Extracted text from the image")
        XCTAssertEqual(descriptor.imageMetadata, "1920 × 1080 · public.png")
        XCTAssertTrue(descriptor.hasThumbnail)
    }

    func testMenuBarHoverPreviewPolicyExcludesPrivateSessionClips() throws {
        let content = try ClipContent.detect(text: "Ordinary local clip")

        XCTAssertTrue(MenuBarHoverPreviewPolicy.allowsPreview(for: presentedClip(content: content)))
        XCTAssertFalse(MenuBarHoverPreviewPolicy.allowsPreview(for: presentedClip(
            content: content,
            origin: .privateSession
        )))
    }

    func testMenuBarHoverPreviewDescriptorListsStoredFileNames() throws {
        let content = try ClipContent(
            type: .fileURLs,
            text: "file:///Users/example/Documents/report.pdf",
            representations: ClipRepresentations(files: [
                try ClipFileReference(url: URL(fileURLWithPath: "/Users/example/Documents/report.pdf")),
                try ClipFileReference(url: URL(fileURLWithPath: "/Users/example/Archive/report.pdf"))
            ])
        )

        let descriptor = MenuBarHoverPreviewDescriptor(clip: presentedClip(content: content))

        XCTAssertEqual(descriptor.contentTypeName, "Files")
        XCTAssertEqual(descriptor.fileNames, ["report.pdf", "report.pdf"])
        XCTAssertEqual(descriptor.text, "file:///Users/example/Documents/report.pdf")
    }

    func testMenuBarHoverPreviewDescriptorPreservesLargeStoredTextForTextKitRendering() throws {
        let largeText = String(repeating: "clipboard content\n", count: 120_000)
        XCTAssertGreaterThan(largeText.utf8.count, 2 * 1_024 * 1_024)

        let descriptor = MenuBarHoverPreviewDescriptor(clip: presentedClip(
            content: try ClipContent(type: .richText, text: largeText)
        ))

        XCTAssertEqual(descriptor.text.utf8.count, largeText.utf8.count)
        XCTAssertEqual(descriptor.text, largeText)
    }

    private func presentedClip(
        content: ClipContent,
        origin: PresentedClip.Origin = .history
    ) -> PresentedClip {
        PresentedClip(
            id: UUID(),
            title: "Clip title",
            content: content,
            date: .now,
            sourceBundleIdentifier: nil,
            origin: origin
        )
    }

    private func reference(kind: ClipAssetKind) throws -> ClipAssetReference {
        try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: kind,
            uniformTypeIdentifier: "public.png",
            byteCount: 12,
            relativePath: "assets/preview.png"
        )
    }
}
