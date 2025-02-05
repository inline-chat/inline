// PhotoPreviewView.swift
import SwiftUI

class PhotoPreviewViewModel: ObservableObject {
  @Published var caption: String = ""
  @Published var isPresented: Bool = false
}

struct PhotoPreviewView: View {
  let image: UIImage
  @Binding var caption: String
  @Binding var isPresented: Bool
  let onSend: (UIImage, String) -> Void

  @FocusState private var isCaptionFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
          .edgesIgnoringSafeArea(.all)

        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: geometry.size.width)
      }
      .overlay(alignment: .topLeading) {
        Button(action: {
          withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
          }
        }) {
          Image(systemName: "xmark")
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(width: 32, height: 32)
            .background(
              Circle()
                .fill(.thickMaterial)
                .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
        }
        .padding(.leading, 16)
        .padding(.top, 16)
      }
      .overlay(alignment: .bottom) {
        HStack(spacing: 12) {
          TextField("Add a caption...", text: $caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
              Capsule()
                .fill(.thickMaterial)
                .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
            .focused($isCaptionFocused)

          Button(action: {
            onSend(image, caption)
            isPresented = false
          }) {
            Image(systemName: "arrow.up")
              .font(.system(size: 20, weight: .semibold))
              .foregroundColor(.white)
              .frame(width: 40, height: 40)
              .background(Color.blue)
              .clipShape(Circle())
          }
          .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(
          LinearGradient(
            colors: [.clear, .black.opacity(0.3)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      }
    }
  }
}

struct ScaleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}
