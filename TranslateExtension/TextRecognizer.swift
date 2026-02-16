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

/// A recognized text block with its bounding box in normalized image coordinates.
struct RecognizedBlock {
    let text: String
    /// Bounding box in normalized image coordinates (origin at bottom-left, y increases upward).
    let boundingBox: CGRect
    /// The vertical center of the block (in top-down coordinates, 0 = top).
    var midY: CGFloat { 1.0 - (boundingBox.origin.y + boundingBox.height / 2) }
    var midX: CGFloat { boundingBox.origin.x + boundingBox.width / 2 }
    var height: CGFloat { boundingBox.height }
}

/// A group of text blocks that appear on the same visual "row" in the image.
struct TextGroup {
    let text: String
    let price: String?

    /// Combined display: "Item name  $price" or just "Item name"
    var displayText: String {
        if let price, !price.isEmpty {
            return "\(text)  \(price)"
        }
        return text
    }

    /// The translatable portion (excludes price)
    var translatableText: String { text }
}

struct TextRecognizer {

    /// Performs OCR and returns grouped text lines.
    /// Lines that are vertically close are merged, with prices separated out.
    static func recognizeGrouped(in image: UIImage) async throws -> [TextGroup] {
        let blocks = try await recognizeBlocks(in: image)
        guard !blocks.isEmpty else { throw RecognitionError.noTextFound }
        return groupBlocks(blocks)
    }

    /// Performs OCR and returns individual positioned text blocks.
    static func recognizeBlocks(in image: UIImage) async throws -> [RecognizedBlock] {
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

                let blocks = observations.compactMap { observation -> RecognizedBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedBlock(
                        text: candidate.string,
                        boundingBox: observation.boundingBox
                    )
                }

                if blocks.isEmpty {
                    continuation.resume(throwing: RecognitionError.noTextFound)
                } else {
                    continuation.resume(returning: blocks)
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

    /// Performs OCR and returns all recognized text as a single string.
    static func recognizeText(in image: UIImage) async throws -> String {
        let blocks = try await recognizeBlocks(in: image)
        guard !blocks.isEmpty else { throw RecognitionError.noTextFound }
        // Sort top-to-bottom, left-to-right
        let sorted = blocks.sorted { a, b in
            if abs(a.midY - b.midY) < 0.01 { return a.midX < b.midX }
            return a.midY < b.midY
        }
        return sorted.map(\.text).joined(separator: "\n")
    }

    // MARK: - Grouping Logic

    /// Groups text blocks that are on the same visual row.
    /// Uses vertical proximity: blocks whose vertical centers are within a threshold
    /// of each other are considered part of the same row.
    private static func groupBlocks(_ blocks: [RecognizedBlock]) -> [TextGroup] {
        guard !blocks.isEmpty else { return [] }

        // Sort blocks top-to-bottom by midY
        let sorted = blocks.sorted { $0.midY < $1.midY }

        // Calculate the median line height to use as grouping threshold
        let heights = sorted.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        // Two blocks are on the same row if their midY values are within half the median height
        let threshold = max(medianHeight * 0.6, 0.008)

        // Group blocks into rows
        var rows: [[RecognizedBlock]] = []
        var currentRow: [RecognizedBlock] = [sorted[0]]
        var currentMidY = sorted[0].midY

        for i in 1..<sorted.count {
            let block = sorted[i]
            if abs(block.midY - currentMidY) <= threshold {
                currentRow.append(block)
            } else {
                rows.append(currentRow)
                currentRow = [block]
                currentMidY = block.midY
            }
        }
        rows.append(currentRow)

        // Convert rows into TextGroups
        return rows.map { row in
            // Sort blocks left-to-right within the row
            let leftToRight = row.sorted { $0.midX < $1.midX }

            // Separate price blocks from text blocks
            var textParts: [String] = []
            var priceParts: [String] = []

            for block in leftToRight {
                if isPriceOrNumber(block.text) {
                    priceParts.append(block.text)
                } else {
                    textParts.append(block.text)
                }
            }

            let text = textParts.joined(separator: " ")
            let price = priceParts.isEmpty ? nil : priceParts.joined(separator: " ")

            // If the entire row is just a price, put it in text (it'll be skipped for translation)
            if text.isEmpty, let price {
                return TextGroup(text: price, price: nil)
            }

            return TextGroup(text: text, price: price)
        }
    }

    /// Checks if a string looks like a price or number.
    private static func isPriceOrNumber(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return false }

        let allowed = CharacterSet.decimalDigits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".,;:/-+()$€£¥₹₩₱฿%#~*xX×"))
        if stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return true
        }

        let pricePatterns = [
            #"^[\$€£¥₹₩₱฿]?\s*\d[\d,.\s]*\d?\s*[\$€£¥₹₩₱฿]?$"#,
            #"^\d[\d,.\s]*\s*(MXN|USD|EUR|GBP|JPY|KRW|THB|PHP|CAD|AUD|COP|PEN|ARS|BRL|CLP|VND|IDR|MYR|SGD|HKD|TWD|CNY|INR|NZD)$"#,
            #"^\d[\d,.\s]*\s*[円元₫]"#,
            #"^[\$€£¥₹₩₱฿]\s*\d[\d,.\s]*\s*[-–~]\s*[\$€£¥₹₩₱฿]?\s*\d[\d,.\s]*$"#,
            #"^\d[\d,.\s]*\s*[-–~/]\s*\d[\d,.\s]*$"#,
        ]
        for pattern in pricePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
                return true
            }
        }

        return false
    }
}
