# Google Maps Translator

Google Maps Translator is an iOS app with a Share Extension that translates text found in Google Maps place photos.

## What it does

- Accepts a shared Google Maps photo URL from the iOS share sheet.
- Resolves redirects and extracts/downloads the underlying image.
- Runs on-device OCR with Vision to detect text and bounding boxes.
- Translates recognized lines using Apple's Translation framework to the device language.
- Shows results in a table view (`Original` -> `Translation`) and a photo overlay view.
- Skips numeric/price-like content so non-linguistic strings are not translated.

## Project structure

- `GoogleMapsTranslator/`: Main SwiftUI app with basic onboarding instructions.
- `TranslateExtension/`: Share Extension pipeline (URL extraction, image loading, OCR, translation, overlays).
- `GoogleMapsTranslator.xcodeproj/`: Xcode project and target configuration.

## Requirements

- Xcode with iOS 18.0 SDK support.
- iOS Deployment Target: 18.0 (app + extension).
- A physical iPhone running iOS 18 is recommended for real share-sheet testing.

## Build and run

1. Open `GoogleMapsTranslator.xcodeproj` in Xcode.
2. Select the `GoogleMapsTranslator` scheme and run once to install the host app.
3. Open Google Maps on the device, open a place photo, and tap `Share`.
4. Choose `Translate` from the share sheet.
5. In the extension UI, use `Table` for source/translated rows or `Photo` for translated overlays on the image.

## Notes

- The extension accepts shared Web URLs and text payloads that contain URLs.
- If a direct image cannot be extracted from URL metadata, the loader falls back to HTML parsing for candidate image links.
- Translation target language follows the device's current locale language.
