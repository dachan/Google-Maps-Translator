import SwiftUI

/// Data for a translated text overlay positioned on the image.
struct TranslatedOverlay: Identifiable {
    let id = UUID()
    let translated: String
    /// Bounding box in normalized Vision coordinates (origin bottom-left, y up).
    let boundingBox: CGRect
}

/// A zoomable image view with translated text overlaid at the original text positions.
struct ImageOverlayView: View {
    let image: UIImage
    let overlays: [TranslatedOverlay]
    @Binding var showOverlay: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let imageSize = fitSize(for: image.size, in: geometry.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageSize.width, height: imageSize.height)

                if showOverlay {
                    overlayLabels(imageSize: imageSize)
                }
            }
            .frame(width: imageSize.width, height: imageSize.height)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture)
            .simultaneousGesture(dragGesture(viewSize: geometry.size, imageSize: imageSize))
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    if scale > 1.0 {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
        }
    }

    // MARK: - Overlay Labels

    @ViewBuilder
    private func overlayLabels(imageSize: CGSize) -> some View {
        ForEach(overlays) { overlay in
            let rect = convertBoundingBox(overlay.boundingBox, imageSize: imageSize)

            Text(overlay.translated)
                .font(.system(size: max(rect.height * 0.65, 8)))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .frame(width: rect.width, height: rect.height, alignment: .leading)
                .background(Color.black.opacity(0.75))
                .cornerRadius(3)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    // MARK: - Coordinate Conversion

    /// Converts Vision normalized coordinates (origin bottom-left) to SwiftUI points (origin top-left).
    private func convertBoundingBox(_ box: CGRect, imageSize: CGSize) -> CGRect {
        let x = box.origin.x * imageSize.width
        let y = (1.0 - box.origin.y - box.height) * imageSize.height
        let width = box.width * imageSize.width
        let height = box.height * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Calculates the size of the image when fit into the container.
    private func fitSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 1.0), 5.0)
                lastScale = scale
                if scale <= 1.0 {
                    withAnimation(.spring(duration: 0.3)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private func dragGesture(viewSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                let newOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampOffset(newOffset, viewSize: viewSize, imageSize: imageSize)
            }
            .onEnded { value in
                guard scale > 1.0 else { return }
                let newOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampOffset(newOffset, viewSize: viewSize, imageSize: imageSize)
                lastOffset = offset
            }
    }

    private func clampOffset(_ proposed: CGSize, viewSize: CGSize, imageSize: CGSize) -> CGSize {
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let maxX = max((scaledWidth - viewSize.width) / 2, 0)
        let maxY = max((scaledHeight - viewSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
