import Foundation
import Vision

public enum LocalVisionOCRError: Error, Equatable, LocalizedError, Sendable {
    case emptyImage
    case imageTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyImage:
            "The image is empty."
        case let .imageTooLarge(byteCount):
            "The image is too large for OCR (\(byteCount) bytes)."
        }
    }
}

public protocol LocalOCRServicing: Sendable {
    func recognizeText(in imageData: Data) async throws -> String?
}

public struct LocalVisionOCRService: LocalOCRServicing, Sendable {
    public typealias Recognizer = @Sendable (Data, [String]) throws -> String?

    public let maximumImageBytes: Int
    public let recognitionLanguages: [String]
    private let recognizer: Recognizer

    public init(
        maximumImageBytes: Int = 12 * 1_024 * 1_024,
        recognitionLanguages: [String] = []
    ) {
        precondition(maximumImageBytes > 0, "OCR image limit must be positive.")
        self.maximumImageBytes = maximumImageBytes
        self.recognitionLanguages = recognitionLanguages
        self.recognizer = Self.performVisionRecognition
    }

    init(
        maximumImageBytes: Int = 12 * 1_024 * 1_024,
        recognitionLanguages: [String] = [],
        recognizer: @escaping Recognizer
    ) {
        precondition(maximumImageBytes > 0, "OCR image limit must be positive.")
        self.maximumImageBytes = maximumImageBytes
        self.recognitionLanguages = recognitionLanguages
        self.recognizer = recognizer
    }

    public func recognizeText(in imageData: Data) async throws -> String? {
        guard !imageData.isEmpty else { throw LocalVisionOCRError.emptyImage }
        guard imageData.count <= maximumImageBytes else {
            throw LocalVisionOCRError.imageTooLarge(imageData.count)
        }
        let recognizer = self.recognizer
        let languages = recognitionLanguages
        return try await Task.detached(priority: .utility) {
            try recognizer(imageData, languages)
        }.value
    }

    private static func performVisionRecognition(
        imageData: Data,
        languages: [String]
    ) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
