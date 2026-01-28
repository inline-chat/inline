import SwiftUI

struct CircularCropView: View {
  let image: UIImage
  var onCrop: (UIImage) -> Void
  @Environment(\.presentationMode) var presentationMode

  @State private var imageScale: CGFloat = 1.0
  @State private var imageOffset: CGSize = .zero
  @GestureState private var gestureImageScale: CGFloat = 1.0
  @GestureState private var gestureImageOffset: CGSize = .zero
  @State private var containerSize: CGSize = .zero
  @State private var appear = false
  @State private var displayImage: UIImage
  @State private var hasInitializedTransform = false

  private let outputSize: CGFloat = 320
  private let baseCircleRatio: CGFloat = 0.82
  private let maxScaleMultiplier: CGFloat = 4.0

  init(image: UIImage, onCrop: @escaping (UIImage) -> Void) {
    self.image = image
    self.onCrop = onCrop
    let normalized = image.imageOrientation == .up ? image : Self.normalizedImage(image)
    _displayImage = State(initialValue: normalized)
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      GeometryReader { geo in
        let diameter = circleDiameter(in: geo.size)
        let minScale = minImageScale(in: geo.size, circleDiameter: diameter)
        let liveScale = clampedScale(imageScale * gestureImageScale, minScale: minScale)
        let rawOffset = CGSize(
          width: imageOffset.width + gestureImageOffset.width,
          height: imageOffset.height + gestureImageOffset.height
        )
        let clampedOffset = clampedImageOffset(
          rawOffset,
          in: geo.size,
          imageScale: liveScale,
          circleDiameter: diameter
        )
        let imageRect = imageFrame(in: geo.size, scale: liveScale, offset: clampedOffset)
        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

        ZStack {
          Image(uiImage: displayImage)
            .resizable()
            .frame(width: imageRect.width, height: imageRect.height)
            .position(x: imageRect.midX, y: imageRect.midY)
            .clipped()
            .ignoresSafeArea()
            .scaleEffect(appear ? 1 : 1.02)
            .animation(.easeOut(duration: 0.4), value: appear)

          ZStack {
            Color.black.opacity(0.5)
            Circle()
              .frame(width: diameter, height: diameter)
              .position(center)
              .blendMode(.destinationOut)
          }
          .compositingGroup()
          .allowsHitTesting(false)

          Circle()
            .stroke(
              LinearGradient(
                colors: [Color.accentColor.opacity(0.7), .white.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 4
            )
            .shadow(color: Color.accentColor.opacity(0.5), radius: 8)
            .frame(width: diameter, height: diameter)
            .position(center)

          Color.clear
            .contentShape(Rectangle())
            .gesture(
              SimultaneousGesture(
                MagnificationGesture()
                  .updating($gestureImageScale) { value, state, _ in
                    state = value
                  }
                  .onEnded { value in
                    let newScale = clampedScale(imageScale * value, minScale: minScale)
                    imageScale = newScale
                    imageOffset = clampedImageOffset(
                      imageOffset,
                      in: geo.size,
                      imageScale: newScale,
                      circleDiameter: diameter
                    )
                  },
                DragGesture()
                  .updating($gestureImageOffset) { value, state, _ in
                    state = value.translation
                  }
                  .onEnded { value in
                    let candidate = CGSize(
                      width: imageOffset.width + value.translation.width,
                      height: imageOffset.height + value.translation.height
                    )
                    imageOffset = clampedImageOffset(
                      candidate,
                      in: geo.size,
                      imageScale: imageScale,
                      circleDiameter: diameter
                    )
                  }
              )
            )
        }
        .onAppear {
          containerSize = geo.size
          let minScale = minImageScale(in: geo.size, circleDiameter: diameter)
          if !hasInitializedTransform {
            imageScale = minScale
            imageOffset = .zero
            hasInitializedTransform = true
          } else {
            if imageScale < minScale {
              imageScale = minScale
            }
            imageOffset = clampedImageOffset(
              imageOffset,
              in: geo.size,
              imageScale: imageScale,
              circleDiameter: diameter
            )
          }
        }
        .onChange(of: geo.size) { newSize in
          containerSize = newSize
          let newDiameter = circleDiameter(in: newSize)
          let minScale = minImageScale(in: newSize, circleDiameter: newDiameter)
          if imageScale < minScale {
            imageScale = minScale
          }
          imageOffset = clampedImageOffset(
            imageOffset,
            in: newSize,
            imageScale: imageScale,
            circleDiameter: newDiameter
          )
        }
      }
      .ignoresSafeArea()

      VStack {
        Spacer()
        HStack(spacing: 12) {
          Button(action: {
            presentationMode.wrappedValue.dismiss()
          }) {
            Text("Cancel")
              .font(.subheadline)
              .foregroundColor(.primary)
              .padding(.vertical, 8)
              .frame(width: 120)
              .background(Color(.systemBackground).opacity(0.8))
              .clipShape(Capsule())
              .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
          }
          Button(action: {
            let cropped = cropImage()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onCrop(cropped)
            presentationMode.wrappedValue.dismiss()
          }) {
            Text("Done")
              .font(.subheadline)
              .foregroundColor(.white)
              .padding(.vertical, 8)
              .frame(width: 120)
              .background(Color.accentColor)
              .clipShape(Capsule())
              .shadow(color: Color.accentColor.opacity(0.3), radius: 6, y: 1)
          }
        }
        .padding(.horizontal)
        .padding(.bottom, 28)
      }
    }
    .onAppear {
      appear = true
    }
  }

  private func cropImage() -> UIImage {
    guard containerSize.width > 0, containerSize.height > 0 else {
      return displayImage
    }

    let diameter = circleDiameter(in: containerSize)
    let minScale = minImageScale(in: containerSize, circleDiameter: diameter)
    let resolvedScale = clampedScale(imageScale, minScale: minScale)
    let clampedOffset = clampedImageOffset(
      imageOffset,
      in: containerSize,
      imageScale: resolvedScale,
      circleDiameter: diameter
    )
    let imageFrame = imageFrame(in: containerSize, scale: resolvedScale, offset: clampedOffset)
    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)

    let imgSize = displayImage.size
    guard imgSize.width > 0, imgSize.height > 0 else {
      return displayImage
    }

    let viewScale = imageFrame.width / imgSize.width
    guard viewScale > 0 else {
      return displayImage
    }
    let imageOrigin = imageFrame.origin

    let imageCenter = CGPoint(
      x: (center.x - imageOrigin.x) / viewScale,
      y: (center.y - imageOrigin.y) / viewScale
    )
    let cropSide = min(diameter / viewScale, imgSize.width, imgSize.height)
    var cropRect = CGRect(
      x: imageCenter.x - cropSide / 2,
      y: imageCenter.y - cropSide / 2,
      width: cropSide,
      height: cropSide
    )
    cropRect.origin.x = min(max(cropRect.origin.x, 0), imgSize.width - cropRect.width)
    cropRect.origin.y = min(max(cropRect.origin.y, 0), imgSize.height - cropRect.height)

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
    return renderer.image { _ in
      let scaleFactor = outputSize / cropRect.width
      let drawRect = CGRect(
        x: -cropRect.origin.x * scaleFactor,
        y: -cropRect.origin.y * scaleFactor,
        width: imgSize.width * scaleFactor,
        height: imgSize.height * scaleFactor
      )
      displayImage.draw(in: drawRect)
    }
  }

  private func circleDiameter(in container: CGSize) -> CGFloat {
    min(container.width, container.height) * baseCircleRatio
  }

  private func minImageScale(in container: CGSize, circleDiameter: CGFloat) -> CGFloat {
    let imageSize = displayImage.size
    guard container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else {
      return 1
    }

    let scaleForWidth = container.width / imageSize.width
    let scaleForCircleHeight = circleDiameter / imageSize.height
    return max(scaleForWidth, scaleForCircleHeight)
  }

  private func clampedScale(_ value: CGFloat, minScale: CGFloat) -> CGFloat {
    let maxScale = minScale * maxScaleMultiplier
    return min(max(value, minScale), maxScale)
  }

  private func clampedImageOffset(
    _ offset: CGSize,
    in container: CGSize,
    imageScale: CGFloat,
    circleDiameter: CGFloat
  ) -> CGSize {
    let imageSize = displayImage.size
    guard imageSize.width > 0, imageSize.height > 0 else {
      return .zero
    }

    let radius = circleDiameter / 2
    let halfWidth = (imageSize.width * imageScale) / 2
    let halfHeight = (imageSize.height * imageScale) / 2

    let minX = radius - halfWidth
    let maxX = -radius + halfWidth
    let minY = radius - halfHeight
    let maxY = -radius + halfHeight

    let clampedX: CGFloat
    if minX > maxX {
      clampedX = 0
    } else {
      clampedX = min(max(offset.width, minX), maxX)
    }

    let clampedY: CGFloat
    if minY > maxY {
      clampedY = 0
    } else {
      clampedY = min(max(offset.height, minY), maxY)
    }

    return CGSize(width: clampedX, height: clampedY)
  }

  private func imageFrame(in container: CGSize, scale: CGFloat, offset: CGSize) -> CGRect {
    let imageSize = displayImage.size
    guard container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else {
      return CGRect(origin: .zero, size: container)
    }

    let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let origin = CGPoint(
      x: (container.width - displaySize.width) / 2 + offset.width,
      y: (container.height - displaySize.height) / 2 + offset.height
    )

    return CGRect(origin: origin, size: displaySize)
  }

  private static func normalizedImage(_ source: UIImage) -> UIImage {
    guard source.imageOrientation != .up else {
      return source
    }
    guard let cgImage = source.cgImage else {
      return source
    }

    let scale = source.scale
    let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    let normalizedSize: CGSize
    switch source.imageOrientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      normalizedSize = CGSize(width: pixelSize.height / scale, height: pixelSize.width / scale)
    default:
      normalizedSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: normalizedSize, format: format)
    return renderer.image { _ in
      source.draw(in: CGRect(origin: .zero, size: normalizedSize))
    }
  }
}

#if DEBUG
struct CircularCropView_Previews: PreviewProvider {
  static var previews: some View {
    CircularCropView(image: UIImage(systemName: "person.crop.circle")!) { _ in }
  }
}
#endif
