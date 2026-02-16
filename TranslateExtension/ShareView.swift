import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var image: UIImage?
    @State private var recognizedText: String = ""
    @State private var translatedText: String = ""
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

                    if !recognizedText.isEmpty {
                        GroupBox {
                            Text(recognizedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } label: {
                            Label("Original Text", systemImage: "doc.text")
                        }
                    }

                    if !translatedText.isEmpty {
                        GroupBox {
                            Text(translatedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } label: {
                            Label("Translation", systemImage: "character.bubble")
                        }
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
                do {
                    let response = try await session.translate(recognizedText)
                    translatedText = response.targetText
                } catch {
                    errorMessage = "Translation failed: \(error.localizedDescription)"
                }
            }
        }
        .task {
            await process()
        }
    }

    private func process() async {
        // Step 1: Extract URL from extension context
        guard let url = await extractSharedURL() else {
            errorMessage = "No URL received from Google Maps."
            isLoading = false
            return
        }

        debugInfo = "Shared URL: \(url.absoluteString)"

        // Step 2: Download the image
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

        // Step 3: Run OCR
        statusMessage = "Recognizing text..."
        do {
            recognizedText = try await TextRecognizer.recognizeText(in: image!)
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

        // Step 4: Trigger translation
        statusMessage = "Translating..."
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        translationConfig = .init(target: Locale.Language(identifier: deviceLanguage))

        isLoading = false
    }

    private func extractSharedURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }

        for item in items {
            guard let attachments = item.attachments else { continue }

            // First pass: look for URL type
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                        if let url = item as? URL {
                            return url
                        }
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            return url
                        }
                    } catch {
                        continue
                    }
                }
            }

            // Second pass: look for plain text that might be a URL
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                        if let text = item as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                           url.scheme?.hasPrefix("http") == true {
                            return url
                        }
                    } catch {
                        continue
                    }
                }
            }
        }
        return nil
    }
}
