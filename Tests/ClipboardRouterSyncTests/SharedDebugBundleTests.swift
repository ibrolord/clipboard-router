import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SharedDebugBundleTests: XCTestCase {
    func testSanitizingPublicationDropsSourceMetadataAndRedactsLocalPaths() throws {
        let item = try ContextPackItem(
            id: UUID(),
            title: "Failure in /Users/alice/work/App.swift",
            textRepresentation: "fatal error at /Users/alice/work/App.swift:42",
            capturedAt: Date(timeIntervalSince1970: 100),
            sourceApplication: "Xcode on Alice's Mac",
            sourceURL: URL(string: "https://internal.example/source?id=42"),
            metadata: [
                "device": "Alice's MacBook",
                "location": "Toronto",
                "bookmark": "opaque-local-capability",
            ]
        )
        let pack = try ContextPack(name: "Bug", items: [item])
        let bundle = try DebugBundleBuilder().build(
            project: try DeveloperProjectContext(
                name: "App",
                rootLabel: "/Users/alice/work/App",
                branch: "fix/crash"
            ),
            from: pack,
            problemStatement: "Crashes under /Users/alice/work/App"
        )

        let publication = try SharedDebugBundlePublication(
            sanitizing: bundle,
            publishedAt: Date(timeIntervalSince1970: 200)
        )
        let encoded = String(decoding: try JSONEncoder().encode(publication), as: UTF8.self)

        XCTAssertTrue(publication.items[0].content.contains("<redacted-local-path>"))
        XCTAssertFalse(encoded.contains("/Users/alice"))
        XCTAssertFalse(encoded.contains("internal.example"))
        XCTAssertFalse(encoded.contains("Xcode on Alice's Mac"))
        XCTAssertFalse(encoded.contains("Alice's MacBook"))
        XCTAssertFalse(encoded.contains("Toronto"))
        XCTAssertFalse(encoded.contains("opaque-local-capability"))
        XCTAssertFalse(encoded.contains(bundle.sourceContextPackID.uuidString))
        XCTAssertNil(publication.branch)
        XCTAssertFalse(encoded.contains("fix/crash"))
    }

    func testDirectPublicationRejectsAbsolutePath() throws {
        for content in [
            "Read /Users/alice/private/key.txt",
            "fatal at /Users/alice/My Secret Project/App.swift:42",
            "path:/Users/alice/private/key.txt",
            "cwd:/Users/alice/Secret Project/App.swift",
            "workspace:/Users/alice/private/App.swift",
            #"Read "/Users/alice/My Secret Project/App.swift" now"#,
            #"Read /Users/alice/My\ Secret\ Project/App.swift"#,
            "Read ~/Private Project/key.txt",
            "Read /tmp",
            "Read file:///Users/alice/private/key.txt",
            #"Read C:\Users\alice\private\key.txt"#,
            #"Read \\server\private share\key.txt"#,
        ] {
            XCTAssertThrowsError(try SharedDebugBundleItem(
                title: "Crash",
                kind: .error,
                languageHint: nil,
                content: content
            )) { error in
                XCTAssertEqual(error as? SharedDebugBundleError, .containsLocalPath)
            }
        }
    }

    func testSanitizingPublicationRemovesCompletePathsWithSpacesAndLabels() throws {
        for content in [
            "fatal at /Users/alice/My Secret Project/App.swift:42",
            "path:/Users/alice/private/key.txt",
            "cwd:/Users/alice/Secret Project/App.swift",
            "workspace:/Users/alice/private/App.swift",
            #"source: "C:\Users\alice\Private Project\App.swift""#,
            #"file: \\server\private share\key.txt"#,
        ] {
            let bundle = try DebugBundle(
                generatedAt: Date(timeIntervalSince1970: 1),
                project: try DeveloperProjectContext(name: "Project"),
                sourceContextPackID: UUID(),
                sourceContextPackName: "Output",
                items: [DebugBundleItem(
                    source: try ContextPackItem(
                        id: UUID(),
                        title: "Failure",
                        textRepresentation: content
                    ),
                    analysis: DeveloperContentRecognizer().analyze(content)
                )],
                maximumRenderedUTF8Bytes: 256 * 1_024
            )
            let publication = try SharedDebugBundlePublication(sanitizing: bundle)
            let rendered = publication.items[0].content
            XCTAssertTrue(rendered.contains("<redacted-local-path>"), content)
            XCTAssertFalse(rendered.contains("alice"), content)
            XCTAssertFalse(rendered.contains("Secret Project"), content)
            XCTAssertFalse(rendered.contains("Private Project"), content)
            XCTAssertFalse(rendered.contains("private share"), content)
        }
    }

}
