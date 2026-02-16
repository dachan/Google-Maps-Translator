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

struct TextRecognizer {

    /// Performs OCR on the given image and returns all recognized text.
    static func recognizeText(in image: UIImage) async throws -> String {
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

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                if text.isEmpty {
                    continuation.resume(throwing: RecognitionError.noTextFound)
                } else {
                    continuation.resume(returning: text)
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
}
