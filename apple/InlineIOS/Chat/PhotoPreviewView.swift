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
        Color(.systemBackground)
          .edgesIgnoringSafeArea(.all)
                
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: geometry.size.width)
      }
      .overlay(alignment: .top) {
        HStack {
          Button(action: { isPresented = false }) {
            Image(systemName: "xmark")
              .foregroundColor(.primary)
              .padding()
          }
                      
          Spacer()
        }
      }
      .overlay(alignment: .bottom) {
        HStack {
          TextField("Add a caption...", text: $caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
              Capsule()
                .fill(Color(.systemBackground))
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
              .frame(width: 32, height: 32)
              .background(
                Circle()
                  .fill(Color.blue)
              )
            
              .contentShape(Circle())
          }
          .buttonStyle(ScaleButtonStyle())
        }
        .padding()
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
