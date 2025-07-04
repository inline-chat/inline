import SwiftUI

public struct PhotoItem: Identifiable {
  public let id = UUID()
  public let image: UIImage
  public var caption: String?

  public init(image: UIImage, caption: String? = nil) {
    self.image = image
    self.caption = caption
  }
}

class MultiPhotoPreviewViewModel: ObservableObject {
  @Published var photoItems: [PhotoItem] = []
  @Published var currentIndex: Int = 0
  @Published var isPresented: Bool = false

  func setPhotos(_ images: [UIImage]) {
    photoItems = images.map { PhotoItem(image: $0, caption: nil) }
    currentIndex = 0
  }

  func updateCaption(at index: Int, caption: String) {
    guard index < photoItems.count else { return }
    photoItems[index].caption = caption.isEmpty ? nil : caption
  }

  var currentPhoto: PhotoItem? {
    guard currentIndex < photoItems.count else { return nil }
    return photoItems[currentIndex]
  }
}

struct MultiPhotoPreviewView: View {
  @ObservedObject var viewModel: MultiPhotoPreviewViewModel
  @Binding var isPresented: Bool
  let onSend: ([PhotoItem]) -> Void

  @FocusState private var isCaptionFocused: Bool
  @State private var currentCaption: String = ""

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
          .edgesIgnoringSafeArea(.all)

        VStack(spacing: 0) {
          // Header with close button and photo counter
          HStack {
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

            Spacer()

            // Photo counter
            Text("\(viewModel.currentIndex + 1) of \(viewModel.photoItems.count)")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                Capsule()
                  .fill(.thickMaterial)
                  .strokeBorder(Color(.systemGray4), lineWidth: 1)
              )

            Spacer()

            // Invisible placeholder for layout balance
            Color.clear
              .frame(width: 32, height: 32)
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)

          // Photo carousel
          TabView(selection: $viewModel.currentIndex) {
            ForEach(Array(viewModel.photoItems.enumerated()), id: \.element.id) { index, photoItem in
              Image(uiImage: photoItem.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: geometry.size.width)
                .tag(index)
            }
          }
          .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
          .onChange(of: viewModel.currentIndex) { oldValue, newValue in
            // Save current caption when switching photos
            if oldValue != newValue, oldValue < viewModel.photoItems.count {
              viewModel.updateCaption(at: oldValue, caption: currentCaption)
            }

            // Load caption for new photo
            if newValue < viewModel.photoItems.count {
              currentCaption = viewModel.photoItems[newValue].caption ?? ""
            }
          }

          Spacer()
        }

        // Bottom caption and send button overlay
        VStack {
          Spacer()

          HStack(spacing: 12) {
            TextField("Add a caption...", text: $currentCaption)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(
                Capsule()
                  .fill(.thickMaterial)
                  .strokeBorder(Color(.systemGray4), lineWidth: 1)
              )
              .focused($isCaptionFocused)
              .onChange(of: currentCaption) { _, newValue in
                // Update caption in real time
                viewModel.updateCaption(at: viewModel.currentIndex, caption: newValue)
              }

            Button(action: {
              // Save current caption before sending
              viewModel.updateCaption(at: viewModel.currentIndex, caption: currentCaption)
              onSend(viewModel.photoItems)
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
    .onAppear {
      // Initialize caption for first photo
      if let firstPhoto = viewModel.photoItems.first {
        currentCaption = firstPhoto.caption ?? ""
      }
    }
  }
}

#Preview {
  MultiPhotoPreviewView(
    viewModel: {
      let vm = MultiPhotoPreviewViewModel()
      vm.setPhotos([
        UIImage(systemName: "photo")!,
        UIImage(systemName: "photo.fill")!,
        UIImage(systemName: "photo.circle")!,
      ])
      return vm
    }(),
    isPresented: .constant(true),
    onSend: { _ in }
  )
}
