import UIKit

enum ImageLoaderError: LocalizedError {
    case noURLReceived
    case noImageFound(detail: String)
    case downloadFailed(statusCode: Int, url: String)
    case invalidImageData
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noURLReceived: return "No URL was received from the share sheet."
        case .noImageFound(let detail): return "Could not find an image. \(detail)"
        case .downloadFailed(let code, let url): return "Download failed (HTTP \(code)) for \(url)"
        case .invalidImageData: return "The downloaded data is not a valid image."
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        }
    }
}

struct ImageLoadResult {
    let image: UIImage
    let resolvedURL: URL?
}

struct ImageLoader {

    private static let maxDimension: CGFloat = 2048

    static func loadImage(from url: URL) async throws -> ImageLoadResult {
        // Strategy 1: If this is a short link (maps.app.goo.gl), resolve the redirect first
        //             then extract the image URL from the resolved Google Maps URL.
        // Strategy 2: If the URL is already a full Google Maps URL, extract directly.
        // Strategy 3: If it's a direct image URL, download it.
        // Strategy 4: Fetch the page and parse HTML for image URLs.

        var targetURL = url

        // If it's a short link, resolve it by following redirects
        if url.host?.contains("goo.gl") == true || url.host?.contains("maps.app") == true {
            if let resolved = await resolveRedirects(for: url) {
                targetURL = resolved
            }
            // If redirect didn't resolve to a different URL, the short link itself becomes
            // the target — the fallback HTML parsing below will handle it
        }

        // Try to extract a googleusercontent image URL from the Maps URL itself
        if let imageURL = extractImageURLFromMapsURL(targetURL) {
            let img = try await downloadImage(from: imageURL)
            return ImageLoadResult(image: img, resolvedURL: imageURL)
        }

        // If the URL looks like a direct image URL, try downloading it
        let host = targetURL.host ?? ""
        if host.contains("googleusercontent.com") || host.contains("ggpht.com") {
            let img = try await downloadImage(from: targetURL)
            return ImageLoadResult(image: img, resolvedURL: targetURL)
        }

        // Fallback: fetch the page and parse HTML
        var pageRequest = URLRequest(url: targetURL)
        pageRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: pageRequest)
        } catch {
            throw ImageLoaderError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...399).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ImageLoaderError.downloadFailed(statusCode: code, url: targetURL.absoluteString)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        // If response is an image
        if contentType.hasPrefix("image/") {
            let img = try decodeAndDownscale(data)
            return ImageLoadResult(image: img, resolvedURL: targetURL)
        }
        if let img = UIImage(data: data) {
            return ImageLoadResult(image: downscale(img), resolvedURL: targetURL)
        }

        // Parse HTML
        if let html = String(data: data, encoding: .utf8) {
            let imageURLs = extractAllImageURLs(from: html)
            for imageURL in imageURLs {
                if let img = try? await downloadImage(from: imageURL) {
                    return ImageLoadResult(image: img, resolvedURL: imageURL)
                }
            }
            let preview = String(html.prefix(300))
            throw ImageLoaderError.noImageFound(detail: "Resolved: \(targetURL.absoluteString)\nFound \(imageURLs.count) candidate URLs\nHTML: \(preview)")
        }

        throw ImageLoaderError.noImageFound(detail: "Not HTML or image. Content-Type: \(contentType)")
    }

    // MARK: - Google Maps URL Parsing

    /// Extracts a googleusercontent.com image URL embedded in a Google Maps URL.
    ///
    /// Google Maps photo URLs encode the image URL in the path/data parameter like:
    ///   `6shttps:%2F%2Fgz0.googleusercontent.com%2F...!7i3024!8i4032`
    /// or after percent-decoding:
    ///   `6shttps://gz0.googleusercontent.com/...!7i3024!8i4032`
    private static func extractImageURLFromMapsURL(_ url: URL) -> URL? {
        // Work with the full URL string (includes path, query, fragment)
        let urlString = url.absoluteString

        // Percent-decode the entire string to normalize
        guard let decoded = urlString.removingPercentEncoding else { return nil }

        // Look for googleusercontent.com URL embedded in the decoded string
        // The pattern is: 6shttps://....googleusercontent.com/...(terminated by ! or & or end of string)
        let patterns = [
            #"6shttps://(gz[0-9]+\.googleusercontent\.com/[^!&\s]+)"#,
            #"6shttps://(lh[0-9]+\.googleusercontent\.com/[^!&\s]+)"#,
            #"6shttps://([a-z0-9-]+\.googleusercontent\.com/[^!&\s]+)"#,
            #"6shttps://([a-z0-9-]+\.ggpht\.com/[^!&\s]+)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(decoded.startIndex..., in: decoded)
            guard let match = regex.firstMatch(in: decoded, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: decoded) else { continue }

            var imageURLString = "https://" + String(decoded[captureRange])

            // Remove size constraints from URL to get full resolution
            // Google appends things like =w430-h372-k-no — remove them to get original
            imageURLString = removeGoogleSizeConstraints(imageURLString)

            if let imageURL = URL(string: imageURLString) {
                return imageURL
            }
        }

        return nil
    }

    /// Removes Google's size constraint suffix (e.g., =w430-h372-k-no) to get full-size image.
    private static func removeGoogleSizeConstraints(_ urlString: String) -> String {
        // Match patterns like =w430-h372-k-no or =s1000 at the end
        guard let regex = try? NSRegularExpression(pattern: #"=w\d+.*$|=s\d+.*$"#) else {
            return urlString
        }
        let range = NSRange(urlString.startIndex..., in: urlString)
        return regex.stringByReplacingMatches(in: urlString, range: range, withTemplate: "")
    }

    // MARK: - Redirect Resolution

    /// Resolves a short URL to its final destination by following HTTP redirects.
    private static func resolveRedirects(for url: URL) async -> URL? {
        let delegate = RedirectTracker()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // Use GET with browser-like headers — Google short links often reject HEAD requests
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            // First check if any redirect in the chain was a Google Maps URL
            // (The RedirectTracker stops following once it sees one)
            if let mapsRedirect = delegate.allRedirects.first(where: { $0.absoluteString.contains("google.com/maps") }) {
                return mapsRedirect
            }

            let resolvedURL = response.url ?? delegate.finalURL

            // If the final response URL is a Maps URL, use it
            if let resolved = resolvedURL,
               resolved.absoluteString.contains("google.com/maps") {
                return resolved
            }

            // Some Google short links redirect via JavaScript/meta refresh instead of HTTP 3xx
            if let html = String(data: data, encoding: .utf8) {
                if let match = firstMatch(pattern: #"<meta[^>]*http-equiv\s*=\s*"?refresh"?[^>]*content\s*=\s*"[^"]*url=([^">\s]+)"#, in: html),
                   let refreshURL = URL(string: match) {
                    return refreshURL
                }
                if let match = firstMatch(pattern: #"<link[^>]*rel\s*=\s*"?canonical"?[^>]*href\s*=\s*"([^"]+)"#, in: html),
                   let canonicalURL = URL(string: match),
                   canonicalURL.absoluteString.contains("google.com/maps") {
                    return canonicalURL
                }
                if let match = firstMatch(pattern: #"(https://www\.google\.com/maps/[^\s"'<>\\]+)"#, in: html),
                   let mapsURL = URL(string: match) {
                    return mapsURL
                }
            }

            return resolvedURL
        } catch {
            // Even if the request failed (e.g. we cancelled it after getting the redirect),
            // the delegate may have captured useful redirect URLs
            if let mapsRedirect = delegate.allRedirects.first(where: { $0.absoluteString.contains("google.com/maps") }) {
                return mapsRedirect
            }
            return delegate.finalURL
        }
    }

    // MARK: - Image Download

    private static func downloadImage(from url: URL) async throws -> UIImage {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...399).contains(httpResponse.statusCode) else {
            throw ImageLoaderError.downloadFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                url: url.absoluteString
            )
        }

        return try decodeAndDownscale(data)
    }

    private static func decodeAndDownscale(_ data: Data) throws -> UIImage {
        guard let image = UIImage(data: data) else {
            throw ImageLoaderError.invalidImageData
        }
        return downscale(image)
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - HTML Parsing (Fallback)

    private static func extractAllImageURLs(from html: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        func add(_ urlString: String) {
            var cleaned = urlString
                .replacingOccurrences(of: "\\u003d", with: "=")
                .replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "\\x3d", with: "=")
                .replacingOccurrences(of: "\\x26", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'>;, \\"))
            while cleaned.hasSuffix("\\") { cleaned = String(cleaned.dropLast()) }
            guard !cleaned.isEmpty, !seen.contains(cleaned), let url = URL(string: cleaned) else { return }
            seen.insert(cleaned)
            urls.append(url)
        }

        // og:image
        for pattern in [
            #"<meta[^>]*property\s*=\s*"og:image"[^>]*content\s*=\s*"([^"]+)""#,
            #"<meta[^>]*content\s*=\s*"([^"]+)"[^>]*property\s*=\s*"og:image""#,
        ] {
            if let match = firstMatch(pattern: pattern, in: html) { add(match) }
        }

        // googleusercontent URLs anywhere
        for pattern in [
            #"(https?://[a-z0-9]+\.googleusercontent\.com/[^\s"'<>\\]+)"#,
            #"(https?://[a-z0-9-]+\.ggpht\.com/[^\s"'<>\\]+)"#,
        ] {
            for match in allMatches(pattern: pattern, in: html) { add(match) }
        }

        // img src
        for match in allMatches(pattern: #"<img[^>]*src\s*=\s*"(https?://[^"]+)""#, in: html) { add(match) }

        // Prefer googleusercontent
        let preferred = urls.filter { ($0.host ?? "").contains("googleusercontent.com") || ($0.host ?? "").contains("ggpht.com") }
        let others = urls.filter { !($0.host ?? "").contains("googleusercontent.com") && !($0.host ?? "").contains("ggpht.com") }
        return preferred + others
    }

    // MARK: - Regex Helpers

    private static func firstMatch(pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range) else { return nil }
        let idx = match.numberOfRanges > 1 ? 1 : 0
        guard let swiftRange = Range(match.range(at: idx), in: string) else { return nil }
        return String(string[swiftRange])
    }

    private static func allMatches(pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            let idx = match.numberOfRanges > 1 ? 1 : 0
            guard let swiftRange = Range(match.range(at: idx), in: string) else { return nil }
            return String(string[swiftRange])
        }
    }
}

// MARK: - Redirect Tracker

private class RedirectTracker: NSObject, URLSessionTaskDelegate {
    var finalURL: URL?
    /// All redirect URLs in order
    var allRedirects: [URL] = []

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url {
            finalURL = url
            allRedirects.append(url)

            // If we got a Google Maps URL, stop following further redirects
            // — we have what we need and further redirects may lead to consent pages
            if url.absoluteString.contains("google.com/maps") {
                completionHandler(nil) // Cancel further redirects
                return
            }
        }
        completionHandler(request)
    }
}
