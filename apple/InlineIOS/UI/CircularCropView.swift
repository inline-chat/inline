import SwiftUI

struct CircularCropView: View {
  let image: UIImage
  var onCrop: (UIImage) -> Void
  @Environment(\.presentationMode) var presentationMode

  @State private var scale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset: CGSize = .zero
  @State private var appear = false

  private let cropSize: CGFloat = 320

  var body: some View {
    ZStack {
      // Blurred background
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .blur(radius: 30)
        .ignoresSafeArea()
        .overlay(Color.black.opacity(0.5).ignoresSafeArea())
        .scaleEffect(appear ? 1 : 1.1)
        .animation(.easeOut(duration: 0.4), value: appear)

      VStack {
        Spacer()
        ZStack {
          // Dimmed overlay with transparent circle
          Color.black.opacity(0.6)
            .mask(
              Circle()
                .frame(width: cropSize, height: cropSize)
                .blendMode(.destinationOut)
                .padding()
            )
            .compositingGroup()
            .allowsHitTesting(false)

          GeometryReader { geo in
            ZStack {
              Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cropSize, height: cropSize)
                .scaleEffect(scale * gestureScale)
                .offset(x: offset.width + gestureOffset.width, y: offset.height + gestureOffset.height)
                .clipShape(Circle())
                .shadow(color: Color.accentColor.opacity(0.25), radius: 16, x: 0, y: 4)
                .gesture(
                  SimultaneousGesture(
                    MagnificationGesture().updating($gestureScale) { value, state, _ in
                      state = value
                    }.onEnded { value in
                      scale *= value
                    },
                    DragGesture().updating($gestureOffset) { value, state, _ in
                      state = value.translation
                    }.onEnded { value in
                      offset.width += value.translation.width
                      offset.height += value.translation.height
                    }
                  )
                )
              // Glowing border
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
                .frame(width: cropSize, height: cropSize)
            }
            .frame(width: geo.size.width, height: geo.size.height)
          }
        }
        .frame(width: cropSize, height: cropSize)
        .scaleEffect(appear ? 1 : 0.95)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appear)
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
    .onAppear { appear = true }
  }

  private func cropImage() -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: cropSize, height: cropSize))
    return renderer.image { ctx in
      let context = ctx.cgContext
      context.addEllipse(in: CGRect(origin: .zero, size: CGSize(width: cropSize, height: cropSize)))
      context.clip()

      // Calculate transform for scale and offset
      let imgSize = image.size
      let scaleFactor = (imgSize.width > imgSize.height ? cropSize / imgSize.height : cropSize / imgSize.width) * scale
      let x = (cropSize - imgSize.width * scaleFactor) / 2 + offset.width
      let y = (cropSize - imgSize.height * scaleFactor) / 2 + offset.height
      image.draw(in: CGRect(x: x, y: y, width: imgSize.width * scaleFactor, height: imgSize.height * scaleFactor))
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
