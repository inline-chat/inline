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

  // MARK: - Layout Constants

  private let closeButtonSize: CGFloat = 32
  private let textFieldHorizontalPadding: CGFloat = 16
  private let textFieldVerticalPadding: CGFloat = 10
  private let counterHorizontalPadding: CGFloat = 12
  private let counterVerticalPadding: CGFloat = 6
  private let bottomContentSpacing: CGFloat = 12
  private let bottomContentPadding: CGFloat = 8
  private let animationDuration: TimeInterval = 0.2

  // Computed properties for consistent sizing
  private var textFieldHeight: CGFloat {
    (textFieldVerticalPadding * 2) + 20 // 20 is approximate font height
  }

  private var sendButtonSize: CGFloat {
    textFieldHeight
  }

  var body: some View {
    NavigationView {
      GeometryReader { geometry in
        ZStack {
          ThemeManager.shared.backgroundColorSwiftUI
            .edgesIgnoringSafeArea(.all)

          VStack(spacing: 0) {
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
              handlePhotoChange(from: oldValue, to: newValue)
            }

            Spacer()
          }
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              closeButton
            }
            ToolbarItem(placement: .topBarTrailing) {
              photoCounter
            }
          }
          .safeAreaInset(edge: .bottom) {
            bottomContent
          }
        }
      }
    }
    .onAppear {
      initializeCaption()
    }
  }

  // MARK: - View Components

  private var closeButton: some View {
    Button(action: {
      withAnimation(.easeOut(duration: animationDuration)) {
        isPresented = false
      }
    }) {
      if #available(iOS 26.0, *) {
        Circle()
          .fill(ThemeManager.shared.cardBackgroundColor)
          .frame(width: closeButtonSize, height: closeButtonSize)
          .overlay {
            Image(systemName: "xmark")
              .font(.callout)
              .foregroundColor(ThemeManager.shared.textPrimaryColor)
          }
          .glassEffect(.regular, in: Circle(), isEnabled: true)
      } else {
        Circle()
          .fill(ThemeManager.shared.surfaceBackgroundColor)
          .frame(width: closeButtonSize, height: closeButtonSize)
          .overlay {
            Image(systemName: "xmark")
              .font(.callout)
              .foregroundColor(ThemeManager.shared.textPrimaryColor)
          }
      }
    }
    .buttonStyle(PlainButtonStyle())
  }

  private var photoCounter: some View {
    HStack(spacing: 2) {
      Text("\(viewModel.currentIndex + 1)")
        .font(.body)
        .foregroundColor(ThemeManager.shared.textPrimaryColor)
      Text("of \(viewModel.photoItems.count)")
        .font(.body)
        .foregroundColor(ThemeManager.shared.textSecondaryColor)
    }
    .padding(.horizontal, counterHorizontalPadding)
    .frame(height: 32)
    .fixedSize(horizontal: true, vertical: false)
    .background {
      if #available(iOS 26.0, *) {
        Capsule()
          .fill(ThemeManager.shared.cardBackgroundColor)
          .glassEffect(.regular, in: Capsule(), isEnabled: true)
      } else {
        Capsule()
          .fill(ThemeManager.shared.surfaceBackgroundColor)
      }
    }
  }

  private var captionTextField: some View {
    TextField("Add a caption...", text: $currentCaption)
      .padding(.horizontal, textFieldHorizontalPadding)
      .padding(.vertical, textFieldVerticalPadding)
      .focused($isCaptionFocused)
      .onChange(of: currentCaption) { _, newValue in
        viewModel.updateCaption(at: viewModel.currentIndex, caption: newValue)
      }
      .background {
        Capsule()
          .stroke(ThemeManager.shared.borderColor, lineWidth: 1)
      }
  }

  private var sendButton: some View {
    Button(action: {
      sendPhotos()
    }) {
      Image(systemName: "arrow.up")
        .foregroundColor(.white)
    }
    .buttonStyle(ScaleButtonStyle())
    .frame(width: sendButtonSize, height: sendButtonSize)
    .background(ThemeManager.shared.accentColor)
    .clipShape(Circle())
  }

  private var bottomContent: some View {
    HStack(spacing: bottomContentSpacing) {
      captionTextField
      sendButton
    }
    .padding(.horizontal)
    .padding(.bottom, bottomContentPadding)
  }

  // MARK: - Helper Methods

  private func handlePhotoChange(from oldValue: Int, to newValue: Int) {
    // Save current caption when switching photos
    if oldValue != newValue, oldValue < viewModel.photoItems.count {
      viewModel.updateCaption(at: oldValue, caption: currentCaption)
    }

    // Load caption for new photo
    if newValue < viewModel.photoItems.count {
      currentCaption = viewModel.photoItems[newValue].caption ?? ""
    }
  }

  private func initializeCaption() {
    if let firstPhoto = viewModel.photoItems.first {
      currentCaption = firstPhoto.caption ?? ""
    }
  }

  private func sendPhotos() {
    viewModel.updateCaption(at: viewModel.currentIndex, caption: currentCaption)
    onSend(viewModel.photoItems)
    isPresented = false
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
