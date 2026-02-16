import SwiftUI
import Translation
import UniformTypeIdentifiers

struct TranslationRow: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
}

struct ShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var image: UIImage?
    @State private var recognizedLines: [String] = []
    @State private var rows: [TranslationRow] = []
    @State private var isLoading = true
    @State private var statusMessage: String = "Loading image..."
    @State private var errorMessage: String?
    @State private var debugInfo: String = ""
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if !rows.isEmpty {
                        translationTable
                    }

                    if isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }

                    if let errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }

                    if !debugInfo.isEmpty {
                        GroupBox {
                            Text(debugInfo)
                                .font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } label: {
                            Label("Debug", systemImage: "ladybug")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
            .translationTask(translationConfig) { session in
                await translateLines(using: session)
            }
        }
        .task {
            await process()
        }
    }

    // MARK: - Translation Table

    private var translationTable: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text("Original")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Divider()
                Text("Translation")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(.systemGray5))

            Divider()

            // Rows
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 0) {
                    Text(row.original)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)

                    Divider()

                    Text(row.translated)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                Divider()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    // MARK: - Translation Logic

    private func translateLines(using session: TranslationSession) async {
        let translatableLines = recognizedLines.filter { !isSkippable($0) }

        guard !translatableLines.isEmpty else {
            // Everything is prices/numbers — show as-is
            rows = recognizedLines.map { TranslationRow(original: $0, translated: $0) }
            return
        }

        // Batch translate only non-skippable lines
        let requests = translatableLines.enumerated().map { (index, line) in
            TranslationSession.Request(sourceText: line, clientIdentifier: "\(index)")
        }

        do {
            let responses = try await session.translations(from: requests)

            var translationMap: [String: String] = [:]
            for response in responses {
                translationMap[response.sourceText] = response.targetText
            }

            rows = recognizedLines.map { line in
                if isSkippable(line) {
                    return TranslationRow(original: line, translated: line)
                } else {
                    let translated = translationMap[line] ?? line
                    return TranslationRow(original: line, translated: translated)
                }
            }
        } catch {
            errorMessage = "Translation failed: \(error.localizedDescription)"
            rows = recognizedLines.map { TranslationRow(original: $0, translated: "") }
        }
    }

    /// Returns true if the text should be skipped for translation (numbers, prices, etc.).
    private func isSkippable(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return true }

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

    // MARK: - Processing Pipeline

    private func process() async {
        guard let url = await extractSharedURL() else {
            errorMessage = "No URL received from Google Maps."
            isLoading = false
            return
        }

        debugInfo = "Shared URL: \(url.absoluteString)"

        statusMessage = "Downloading image..."
        do {
            let result = try await ImageLoader.loadImage(from: url)
            image = result.image
            debugInfo += "\nResolved URL: \(result.resolvedURL?.absoluteString ?? "direct")"
        } catch {
            errorMessage = error.localizedDescription
            if let loaderError = error as? ImageLoaderError {
                debugInfo += "\nError detail: \(loaderError)"
            }
            isLoading = false
            return
        }

        statusMessage = "Recognizing text..."
        do {
            let fullText = try await TextRecognizer.recognizeText(in: image!)
            recognizedLines = fullText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } catch {
            if let recognitionError = error as? RecognitionError,
               case .noTextFound = recognitionError {
                errorMessage = "No text was found in this image."
            } else {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }

        statusMessage = "Translating..."
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        translationConfig = .init(target: Locale.Language(identifier: deviceLanguage))

        isLoading = false
    }

    // MARK: - URL Extraction

    private func extractSharedURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }

        for item in items {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                        if let url = item as? URL { return url }
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
                    } catch { continue }
                }
            }

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                        if let text = item as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                           url.scheme?.hasPrefix("http") == true { return url }
                    } catch { continue }
                }
            }
        }
        return nil
    }
}
