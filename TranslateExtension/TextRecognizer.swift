import Vision
import UIKit

enum RecognitionError: LocalizedError {
    case invalidImage
    case recognitionFailed(Error)
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not process the image."
        case .recognitionFailed(let error): return "Text recognition failed: \(error.localizedDescription)"
        case .noTextFound: return "No text was found in the image."
        }
    }
}

/// A recognized text block with its bounding box in normalized Vision coordinates.
struct PositionedText: Identifiable {
    let id = UUID()
    let text: String
    /// Bounding box in normalized image coordinates (origin at bottom-left, y increases upward).
    let boundingBox: CGRect
}

struct TextRecognizer {

    /// Performs OCR and returns text with bounding box positions.
    static func recognizeWithPositions(in image: UIImage) async throws -> [PositionedText] {
        guard let cgImage = image.cgImage else {
            throw RecognitionError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: RecognitionError.recognitionFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: RecognitionError.noTextFound)
                    return
                }

                let results = observations.compactMap { observation -> PositionedText? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return PositionedText(
                        text: candidate.string,
                        boundingBox: observation.boundingBox
                    )
                }

                if results.isEmpty {
                    continuation.resume(throwing: RecognitionError.noTextFound)
                } else {
                    continuation.resume(returning: results)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: RecognitionError.recognitionFailed(error))
            }
        }
    }

    /// Performs OCR on the given image and returns all recognized text as a single string.
    static func recognizeText(in image: UIImage) async throws -> String {
        let positioned = try await recognizeWithPositions(in: image)
        return positioned.map(\.text).joined(separator: "\n")
    }
}
