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

class SwiftUIPhotoPreviewViewModel: ObservableObject {
  @Published var photoItems: [PhotoItem] = []
  @Published var currentIndex: Int = 0
  @Published var isPresented: Bool = false
  @Published var caption: String = ""

  func setPhotos(_ images: [UIImage]) {
    photoItems = images.map { PhotoItem(image: $0, caption: nil) }
    currentIndex = 0
    if let firstPhoto = photoItems.first {
      caption = firstPhoto.caption ?? ""
    }
  }

  func setSinglePhoto(_ image: UIImage, caption: String = "") {
    photoItems = [PhotoItem(image: image, caption: caption.isEmpty ? nil : caption)]
    currentIndex = 0
    self.caption = caption
  }

  func addPhoto(_ image: UIImage) {
    // Save current caption before adding new photo
    if currentIndex < photoItems.count {
      updateCaption(at: currentIndex, caption: caption)
    }

    photoItems.append(PhotoItem(image: image, caption: nil))
  }

  func addPhotos(_ images: [UIImage]) {
    // Save current caption before adding new photos
    if currentIndex < photoItems.count {
      updateCaption(at: currentIndex, caption: caption)
    }

    let newPhotoItems = images.map { PhotoItem(image: $0, caption: nil) }
    photoItems.append(contentsOf: newPhotoItems)
  }

  func removePhoto(at index: Int) {
    guard index < photoItems.count else { return }

    // Always save current caption before any photo removal
    updateCaption(at: currentIndex, caption: caption)

    let wasCurrentPhoto = currentIndex == index
    let transitioningToSingle = photoItems.count == 2 // Will become 1 after removal

    photoItems.remove(at: index)

    if photoItems.isEmpty {
      currentIndex = 0
      caption = ""
    } else {
      if currentIndex >= photoItems.count {
        currentIndex = photoItems.count - 1
      }

      // When transitioning to single photo mode, preserve the current caption
      if transitioningToSingle {
        // Keep current caption text, don't reload from photo item
        updateCaption(at: currentIndex, caption: caption)
      } else if wasCurrentPhoto {
        // If we removed current photo but still in multi-photo mode, load new photo's caption
        updateCaptionForCurrentPhoto()
      }
      // If we removed a different photo, keep current caption as-is
    }
  }

  func updateCaption(at index: Int, caption: String) {
    guard index < photoItems.count else { return }
    photoItems[index].caption = caption.isEmpty ? nil : caption
  }

  func updateCaptionForCurrentPhoto() {
    guard currentIndex < photoItems.count else { return }
    caption = photoItems[currentIndex].caption ?? ""
  }

  var currentPhoto: PhotoItem? {
    guard currentIndex < photoItems.count else { return nil }
    return photoItems[currentIndex]
  }

  var hasMultiplePhotos: Bool {
    photoItems.count > 1
  }
}

struct SwiftUIPhotoPreviewView: View {
  @ObservedObject var viewModel: SwiftUIPhotoPreviewViewModel
  @Binding var isPresented: Bool
  let onSend: ([PhotoItem]) -> Void
  let onAddMorePhotos: (() -> Void)?
  let onSave: ((UIImage) -> Void)? = nil
  let onShare: ((UIImage) -> Void)? = nil

  // Legacy single photo constructor
  init(
    image: UIImage,
    caption: Binding<String>,
    isPresented: Binding<Bool>,
    onSend: @escaping (UIImage, String) -> Void,
    onAddMorePhotos: (() -> Void)? = nil
  ) {
    let vm = SwiftUIPhotoPreviewViewModel()
    vm.setSinglePhoto(image, caption: caption.wrappedValue)
    viewModel = vm
    _isPresented = isPresented
    self.onAddMorePhotos = onAddMorePhotos
    self.onSend = { photoItems in
      if let firstPhoto = photoItems.first {
        onSend(firstPhoto.image, firstPhoto.caption ?? "")
      }
    }
  }

  // Multi photo constructor
  init(
    viewModel: SwiftUIPhotoPreviewViewModel,
    isPresented: Binding<Bool>,
    onSend: @escaping ([PhotoItem]) -> Void,
    onAddMorePhotos: (() -> Void)? = nil
  ) {
    self.viewModel = viewModel
    _isPresented = isPresented
    self.onSend = onSend
    self.onAddMorePhotos = onAddMorePhotos
  }

  @State private var scale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @State private var lastScale: CGFloat = 1.0
  @State private var lastOffset: CGSize = .zero
  @State private var keyboardHeight: CGFloat = 0
  @State private var wasMultiplePhotos: Bool = false

  @FocusState private var isCaptionFocused: Bool

  private let minScale: CGFloat = 0.5
  private let maxScale: CGFloat = 3.0

  // MARK: - Layout Constants

  private let closeButtonSize: CGFloat = 44
  private let actionButtonSize: CGFloat = 44
  private let textFieldHorizontalPadding: CGFloat = 16
  private let textFieldVerticalPadding: CGFloat = 12
  private let bottomContentSpacing: CGFloat = 12
  private let bottomContentPadding: CGFloat = 20
  private let animationDuration: TimeInterval = 0.3
  private let thumbnailSize: CGFloat = 50
  private let thumbnailSpacing: CGFloat = 4
  private let previewStripHeight: CGFloat = 68

  // Computed properties for consistent sizing
  private var sendButtonSize: CGFloat {
    44
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Background
        ThemeManager.shared.backgroundColorSwiftUI
          .ignoresSafeArea()

        // Main image with zoom and pan
        if let currentPhoto = viewModel.currentPhoto {
          if viewModel.hasMultiplePhotos {
            TabView(selection: $viewModel.currentIndex) {
              ForEach(Array(viewModel.photoItems.enumerated()), id: \.element.id) { index, photoItem in
                Image(uiImage: photoItem.image)
                  .resizable()
                  .scaledToFit()
                  .frame(
                    maxWidth: geometry.size.width * 0.95,
                    maxHeight: geometry.size.height * 0.8
                  )
                  .tag(index)
              }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .onChange(of: viewModel.currentIndex) { oldValue, newValue in
              handlePhotoChange(from: oldValue, to: newValue)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
          } else {
            Image(uiImage: currentPhoto.image)
              .resizable()
              .scaledToFit()
              .frame(
                maxWidth: geometry.size.width * 0.95,
                maxHeight: geometry.size.height * 0.8
              )
              .scaleEffect(scale)
              .offset(offset)
              .gesture(zoomAndPanGesture(geometry: geometry))
              .onTapGesture(count: 2) {
                doubleTapToZoom()
              }
          }
        }

        // Top controls
      }
    }
    .overlay(alignment: .topLeading) {
      closeButton
        .padding(.leading, 16)
        .padding(.top, 16)
    }
    .overlay(alignment: .topTrailing) {
      if viewModel.hasMultiplePhotos {
        photoCounter
          .padding(.trailing, 16)
          .padding(.top, 16)
      }
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 0) {
        if !isCaptionFocused, viewModel.hasMultiplePhotos {
          photoPreviewStrip
        }
        bottomContent
      }
    }
    .statusBarHidden()
    .onAppear {
      setupKeyboardObservers()
      viewModel.updateCaptionForCurrentPhoto()
      wasMultiplePhotos = viewModel.hasMultiplePhotos
    }
    .onChange(of: viewModel.hasMultiplePhotos) { _, newValue in
      // Detect transition from multiple to single photo mode
      if wasMultiplePhotos, !newValue {
        // Preserve current caption when transitioning to single photo mode
        viewModel.updateCaption(at: viewModel.currentIndex, caption: viewModel.caption)
      }
      wasMultiplePhotos = newValue
    }
    .onDisappear {
      removeKeyboardObservers()
    }
  }

  // MARK: - View Components

  private var closeButton: some View {
    Button(action: {
      withAnimation(.easeOut(duration: 0.2)) {
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
    .buttonStyle(ScaleButtonStyle2())
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
    .padding(.horizontal, 12)
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

  // Displays the total number of photos in a circular badge shown in the
  // top-bar trailing position. It is hidden when there is only one photo.
  private var photoCountCircle: some View {
    Group {
      if viewModel.photoItems.count > 1 {
        Text("\(viewModel.currentIndex + 1)")
          .font(.callout.bold())
          .foregroundColor(ThemeManager.shared.textPrimaryColor)
          .frame(width: closeButtonSize, height: closeButtonSize)
          .background(
            Group {
              if #available(iOS 26.0, *) {
                Circle()
                  .fill(ThemeManager.shared.cardBackgroundColor)
                  .glassEffect(.regular, in: Circle(), isEnabled: true)
              } else {
                Circle()
                  .fill(ThemeManager.shared.surfaceBackgroundColor)
              }
            }
          )
      }
    }
  }

  private var photoPreviewStrip: some View {
    GeometryReader { geometry in
      let stripWidth = geometry.size.width
      let totalThumbnailsWidth = CGFloat(viewModel.photoItems.count) * thumbnailSize +
        CGFloat(viewModel.photoItems.count - 1) * thumbnailSpacing
      let shouldCenter = totalThumbnailsWidth < stripWidth - (bottomContentPadding * 2)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: thumbnailSpacing) {
          ForEach(Array(viewModel.photoItems.enumerated()), id: \.element.id) { index, photoItem in
            ZStack {
              Image(uiImage: photoItem.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipped()
                .cornerRadius(8)
                .overlay {
                  ZStack {
                    RoundedRectangle(cornerRadius: 8)
                      .fill(Color.black.opacity(0.2))
                      .stroke(
                        index == viewModel.currentIndex ? ThemeManager.shared.accentColor : Color.clear,
                        lineWidth: 2
                      )
                    if viewModel.currentIndex == index {
                      Image(systemName: "trash.fill")
                        .foregroundColor(.white)
                        .font(.body)
                    }
                  }
                }
                .onTapGesture {
                  withAnimation(.easeInOut(duration: 0.2)) {
                    if viewModel.currentIndex != index {
                      viewModel.currentIndex = index
                      viewModel.updateCaptionForCurrentPhoto()
                    } else {
                      viewModel.removePhoto(at: index)
                    }
                  }
                }
            }
          }
        }
        .padding(.horizontal, bottomContentPadding)
        .frame(
          width: max(totalThumbnailsWidth + (bottomContentPadding * 2), stripWidth),
          alignment: shouldCenter ? .center : .leading
        )
      }
    }
    .frame(height: previewStripHeight)
  }

  private var captionTextField: some View {
    TextField("Add a caption...", text: $viewModel.caption, axis: .vertical)
      .focused($isCaptionFocused)
      .font(.system(size: 16))
      .foregroundColor(ThemeManager.shared.textPrimaryColor)
      .padding(.horizontal, textFieldHorizontalPadding)
      .padding(.vertical, textFieldVerticalPadding)
      .background {
        RoundedRectangle(cornerRadius: 20)
          .fill(ThemeManager.shared.backgroundColorSwiftUI)
          .stroke(ThemeManager.shared.borderColor, lineWidth: 1)
      }
      .lineLimit(isCaptionFocused ? (1 ... 4) : (1 ... 1))
      .onChange(of: viewModel.caption) { _, newValue in
        viewModel.updateCaption(at: viewModel.currentIndex, caption: newValue)
      }
      .onSubmit {
        finishEditingCaption()
      }
      .submitLabel(.done)
      .onTapGesture {
        if !isCaptionFocused {
          isCaptionFocused = true
        }
      }
  }

  private func actionButton(systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      if #available(iOS 26.0, *) {
        Circle()
          .fill(ThemeManager.shared.cardBackgroundColor)
          .frame(width: actionButtonSize, height: actionButtonSize)
          .overlay {
            Image(systemName: systemImage)
              .font(.system(size: 18, weight: .medium))
              .foregroundColor(ThemeManager.shared.textPrimaryColor)
          }
          .glassEffect(.regular, in: Circle(), isEnabled: true)
      } else {
        Circle()
          .fill(ThemeManager.shared.surfaceBackgroundColor)
          .frame(width: actionButtonSize, height: actionButtonSize)
          .overlay {
            Image(systemName: systemImage)
              .font(.system(size: 18, weight: .medium))
              .foregroundColor(ThemeManager.shared.textPrimaryColor)
          }
      }
    }
    .buttonStyle(ScaleButtonStyle2())
  }

  private var sendButton: some View {
    Button(action: {
      if isCaptionFocused {
        finishEditingCaption()
      } else {
        sendPhotos()
      }
    }) {
      Image(systemName: isCaptionFocused ? "checkmark" : "arrow.up")
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: sendButtonSize, height: sendButtonSize)
        .background(
          Circle()
            .fill(ThemeManager.shared.accentColor)
        )
    }
    .buttonStyle(ScaleButtonStyle2())
  }

  private var bottomContent: some View {
    HStack(alignment: .bottom, spacing: bottomContentSpacing) {
      captionTextField
      sendButton
    }
    .padding(.horizontal, bottomContentPadding)
    .padding(.bottom, keyboardHeight > 0 ? 8 : bottomContentPadding)
  }

  // MARK: - Actions

  private func finishEditingCaption() {
    isCaptionFocused = false
    // Update the caption for the current photo
    viewModel.updateCaption(at: viewModel.currentIndex, caption: viewModel.caption)
  }

  private func handlePhotoChange(from oldValue: Int, to newValue: Int) {
    // Save current caption when switching photos
    if oldValue != newValue, oldValue < viewModel.photoItems.count {
      viewModel.updateCaption(at: oldValue, caption: viewModel.caption)
    }

    // Load caption for new photo
    viewModel.updateCaptionForCurrentPhoto()

    // Exit caption editing mode when switching photos
    if isCaptionFocused {
      isCaptionFocused = false
    }
  }

  private func sendPhotos() {
    // Update current photo's caption before sending
    viewModel.updateCaption(at: viewModel.currentIndex, caption: viewModel.caption)
    onSend(viewModel.photoItems)
    isPresented = false
  }

  private func zoomAndPanGesture(geometry: GeometryProxy) -> some Gesture {
    SimultaneousGesture(
      // Magnification gesture
      MagnificationGesture()
        .onChanged { value in
          let newScale = lastScale * value
          scale = min(max(newScale, minScale), maxScale)
        }
        .onEnded { _ in
          lastScale = scale

          // Snap back if too small
          if scale < 1.0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
              scale = 1.0
              offset = .zero
            }
            lastScale = 1.0
            lastOffset = .zero
          }
        },

      // Drag gesture
      DragGesture()
        .onChanged { value in
          let newOffset = CGSize(
            width: lastOffset.width + value.translation.width,
            height: lastOffset.height + value.translation.height
          )
          offset = newOffset
        }
        .onEnded { _ in
          lastOffset = offset

          // Snap back to center if scale is 1.0
          if scale <= 1.0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
              offset = .zero
            }
            lastOffset = .zero
          } else {
            // Constrain offset to keep image visible
            let maxOffsetX = (geometry.size.width * (scale - 1)) / 2
            let maxOffsetY = (geometry.size.height * (scale - 1)) / 2

            let constrainedOffset = CGSize(
              width: min(max(offset.width, -maxOffsetX), maxOffsetX),
              height: min(max(offset.height, -maxOffsetY), maxOffsetY)
            )

            if constrainedOffset != offset {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                offset = constrainedOffset
              }
              lastOffset = constrainedOffset
            }
          }
        }
    )
  }

  private func doubleTapToZoom() {
    // Double tap to zoom
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
      if scale > 1.0 {
        scale = 1.0
        offset = .zero
      } else {
        scale = 2.0
      }
    }
    lastScale = scale
    lastOffset = offset
  }

  private func saveImage() {
    guard let currentPhoto = viewModel.currentPhoto else { return }
    UIImageWriteToSavedPhotosAlbum(currentPhoto.image, nil, nil, nil)

    // Show success feedback
    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    impactFeedback.impactOccurred()

    // Optional callback
    onSave?(currentPhoto.image)
  }

  private func shareImage() {
    guard let currentPhoto = viewModel.currentPhoto else { return }
    let activityViewController = UIActivityViewController(
      activityItems: [currentPhoto.image],
      applicationActivities: nil
    )

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first,
       let rootViewController = window.rootViewController
    {
      // Handle iPad popover presentation
      if let popoverController = activityViewController.popoverPresentationController {
        popoverController.sourceView = window
        popoverController.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        popoverController.permittedArrowDirections = []
      }

      rootViewController.present(activityViewController, animated: true)
    }

    // Optional callback
    onShare?(currentPhoto.image)
  }

  // MARK: - Keyboard Handling

  private func setupKeyboardObservers() {
    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { notification in
      if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
        withAnimation(.easeInOut(duration: animationDuration)) {
          keyboardHeight = keyboardFrame.height
        }
      }
    }

    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeInOut(duration: animationDuration)) {
        keyboardHeight = 0
      }
    }
  }

  private func removeKeyboardObservers() {
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
  }
}

// MARK: - Button Styles

struct ScaleButtonStyle2: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - Preview

#Preview {
  let vm = SwiftUIPhotoPreviewViewModel()
  vm.setPhotos([
    UIImage(systemName: "photo")!,
    UIImage(systemName: "photo.fill")!,
    UIImage(systemName: "photo.circle")!,
  ])

  return SwiftUIPhotoPreviewView(
    viewModel: vm,
    isPresented: .constant(true),
    onSend: { _ in },
    onAddMorePhotos: {}
  )
}
