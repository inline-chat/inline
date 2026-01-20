import SwiftUI

struct CircularCropView: View {
  let image: UIImage
  var onCrop: (UIImage) -> Void
  @Environment(\.presentationMode) var presentationMode

  @State private var circleScale: CGFloat = 1.0
  @State private var circleOffset: CGSize = .zero
  @GestureState private var gestureCircleScale: CGFloat = 1.0
  @GestureState private var gestureCircleOffset: CGSize = .zero
  @State private var containerSize: CGSize = .zero
  @State private var appear = false
  @State private var displayImage: UIImage

  private let outputSize: CGFloat = 320
  private let baseCircleRatio: CGFloat = 0.7
  private let minCircleScale: CGFloat = 0.45
  private let maxCircleScale: CGFloat = 1.6

  init(image: UIImage, onCrop: @escaping (UIImage) -> Void) {
    self.image = image
    self.onCrop = onCrop
    _displayImage = State(initialValue: image)
  }

  var body: some View {
    ZStack {
      GeometryReader { geo in
        let imageRect = imageFrame(in: geo.size)
        let baseDiameter = min(imageRect.width, imageRect.height) * baseCircleRatio
        let liveScale = clampedScale(circleScale * gestureCircleScale)
        let diameter = baseDiameter * liveScale
        let rawOffset = CGSize(
          width: circleOffset.width + gestureCircleOffset.width,
          height: circleOffset.height + gestureCircleOffset.height
        )
        let clampedOffset = clampedCircleOffset(
          rawOffset,
          in: geo.size,
          diameter: diameter,
          imageFrame: imageRect
        )
        let center = CGPoint(
          x: geo.size.width / 2 + clampedOffset.width,
          y: geo.size.height / 2 + clampedOffset.height
        )

        ZStack {
          Image(uiImage: displayImage)
            .resizable()
            .scaledToFit()
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

          Circle()
            .fill(Color.clear)
            .frame(width: diameter, height: diameter)
            .position(center)
            .contentShape(Circle())
            .gesture(
              SimultaneousGesture(
                MagnificationGesture()
                  .updating($gestureCircleScale) { value, state, _ in
                    state = value
                  }
                  .onEnded { value in
                    let newScale = clampedScale(circleScale * value)
                    circleScale = newScale
                    let newDiameter = baseDiameter * newScale
                    circleOffset = clampedCircleOffset(
                      circleOffset,
                      in: geo.size,
                      diameter: newDiameter,
                      imageFrame: imageRect
                    )
                  },
                DragGesture()
                  .updating($gestureCircleOffset) { value, state, _ in
                    state = value.translation
                  }
                  .onEnded { value in
                    let candidate = CGSize(
                      width: circleOffset.width + value.translation.width,
                      height: circleOffset.height + value.translation.height
                    )
                    circleOffset = clampedCircleOffset(
                      candidate,
                      in: geo.size,
                      diameter: baseDiameter * circleScale,
                      imageFrame: imageRect
                    )
                  }
              )
            )
        }
        .onAppear {
          containerSize = geo.size
        }
        .onChange(of: geo.size) { newSize in
          containerSize = newSize
          let newImageFrame = imageFrame(in: newSize)
          let newDiameter = min(newImageFrame.width, newImageFrame.height) * baseCircleRatio * circleScale
          circleOffset = clampedCircleOffset(
            circleOffset,
            in: newSize,
            diameter: newDiameter,
            imageFrame: newImageFrame
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
      if displayImage.imageOrientation != .up {
        displayImage = normalizedImage(displayImage)
      }
    }
  }

  private func cropImage() -> UIImage {
    guard containerSize.width > 0, containerSize.height > 0 else {
      return displayImage
    }

    let imageFrame = imageFrame(in: containerSize)
    let baseDiameter = min(imageFrame.width, imageFrame.height) * baseCircleRatio
    let diameter = baseDiameter * circleScale
    let clampedOffset = clampedCircleOffset(
      circleOffset,
      in: containerSize,
      diameter: diameter,
      imageFrame: imageFrame
    )
    let center = CGPoint(
      x: containerSize.width / 2 + clampedOffset.width,
      y: containerSize.height / 2 + clampedOffset.height
    )

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

  private func clampedScale(_ value: CGFloat) -> CGFloat {
    min(max(value, minCircleScale), maxCircleScale)
  }

  private func clampedCircleOffset(
    _ offset: CGSize,
    in container: CGSize,
    diameter: CGFloat,
    imageFrame: CGRect
  ) -> CGSize {
    let radius = diameter / 2
    let containerCenter = CGPoint(x: container.width / 2, y: container.height / 2)
    let desiredCenter = CGPoint(
      x: containerCenter.x + offset.width,
      y: containerCenter.y + offset.height
    )

    let minX = imageFrame.minX + radius
    let maxX = imageFrame.maxX - radius
    let minY = imageFrame.minY + radius
    let maxY = imageFrame.maxY - radius

    let clampedX: CGFloat
    if minX > maxX {
      clampedX = imageFrame.midX
    } else {
      clampedX = min(max(desiredCenter.x, minX), maxX)
    }

    let clampedY: CGFloat
    if minY > maxY {
      clampedY = imageFrame.midY
    } else {
      clampedY = min(max(desiredCenter.y, minY), maxY)
    }

    return CGSize(width: clampedX - containerCenter.x, height: clampedY - containerCenter.y)
  }

  private func imageFrame(in container: CGSize) -> CGRect {
    let imageSize = displayImage.size
    guard container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else {
      return CGRect(origin: .zero, size: container)
    }

    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let origin = CGPoint(
      x: (container.width - displaySize.width) / 2,
      y: (container.height - displaySize.height) / 2
    )

    return CGRect(origin: origin, size: displaySize)
  }

  private func normalizedImage(_ source: UIImage) -> UIImage {
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
