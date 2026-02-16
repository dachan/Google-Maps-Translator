import SwiftUI
import Translation
import UniformTypeIdentifiers

struct TranslationRow: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    let price: String?
}

struct ShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var image: UIImage?
    @State private var textGroups: [TextGroup] = []
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
                await translateGroups(using: session)
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
                    // Original column: text + price
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.original)
                            .font(.body)
                        if let price = row.price {
                            Text(price)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)

                    Divider()

                    // Translation column: translated text + price
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.translated)
                            .font(.body)
                        if let price = row.price {
                            Text(price)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private func translateGroups(using session: TranslationSession) async {
        // Collect groups that have translatable text (not just prices/numbers)
        let translatableGroups = textGroups.filter { !isSkippable($0.translatableText) }

        guard !translatableGroups.isEmpty else {
            // Everything is prices/numbers
            rows = textGroups.map { TranslationRow(original: $0.text, translated: $0.text, price: $0.price) }
            return
        }

        // Batch translate
        let requests = translatableGroups.enumerated().map { (index, group) in
            TranslationSession.Request(sourceText: group.translatableText, clientIdentifier: "\(index)")
        }

        do {
            let responses = try await session.translations(from: requests)

            var translationMap: [String: String] = [:]
            for response in responses {
                translationMap[response.sourceText] = response.targetText
            }

            rows = textGroups.map { group in
                if isSkippable(group.translatableText) {
                    return TranslationRow(original: group.text, translated: group.text, price: group.price)
                } else {
                    let translated = translationMap[group.translatableText] ?? group.translatableText
                    return TranslationRow(original: group.text, translated: translated, price: group.price)
                }
            }
        } catch {
            errorMessage = "Translation failed: \(error.localizedDescription)"
            rows = textGroups.map { TranslationRow(original: $0.text, translated: "", price: $0.price) }
        }
    }

    /// Returns true if the text should be skipped for translation.
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
            textGroups = try await TextRecognizer.recognizeGrouped(in: image!)
            debugInfo += "\nGroups: \(textGroups.count)"
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
