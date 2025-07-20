import SwiftUI

struct SwiftUIPhotoPreviewView: View {
  let image: UIImage
  @Binding var caption: String
  @Binding var isPresented: Bool
  let onSend: (UIImage, String) -> Void
  let onSave: ((UIImage) -> Void)? = nil
  let onShare: ((UIImage) -> Void)? = nil

  @State private var scale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @State private var lastScale: CGFloat = 1.0
  @State private var lastOffset: CGSize = .zero
  @State private var showingActions = true
  @State private var keyboardHeight: CGFloat = 0

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
          .onTapGesture {
            withAnimation(.easeInOut(duration: animationDuration)) {
              showingActions.toggle()
            }
          }

        // Main image with zoom and pan
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxHeight: geometry.size.height * 0.6)
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
          .scaleEffect(scale)
          .offset(offset)
          .gesture(
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
          )
          .onTapGesture(count: 2) {
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

        // Top controls
        if showingActions {
          VStack {
            HStack {
              // Close button
              closeButton

              Spacer()
            }
            .padding(.horizontal, bottomContentPadding)
            .padding(.top, bottomContentPadding)

            Spacer()
          }
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        // Bottom caption and send controls
        if showingActions {
          VStack {
            Spacer()

            bottomContent
          }
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
    }
    .statusBarHidden()
    .onAppear {
      setupKeyboardObservers()
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

  private var captionTextField: some View {
    TextField("Add a caption...", text: $caption, axis: .vertical)
      .focused($isCaptionFocused)
      .font(.system(size: 16))
      .foregroundColor(ThemeManager.shared.textPrimaryColor)
      .padding(.horizontal, textFieldHorizontalPadding)
      .padding(.vertical, textFieldVerticalPadding)
      .background {
        RoundedRectangle(cornerRadius: 20)
          .stroke(ThemeManager.shared.borderColor, lineWidth: 1)
      }
      .lineLimit(1 ... 4)
  }

  private var sendButton: some View {
    Button(action: {
      sendImage()
    }) {
      Image(systemName: "arrow.up")
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: sendButtonSize, height: sendButtonSize)
        .background(
          Circle()
            .fill(ThemeManager.shared.accentColor)
            .shadow(color: ThemeManager.shared.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
        )
    }
    .buttonStyle(ScaleButtonStyle2())
    .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil)
  }

  private var bottomContent: some View {
    HStack(spacing: bottomContentSpacing) {
      captionTextField
      sendButton
    }
    .padding(.horizontal, bottomContentPadding)
    .padding(.bottom, keyboardHeight > 0 ? 8 : bottomContentPadding)
  }

  // MARK: - Actions

  private func sendImage() {
    onSend(image, caption)
  }

  private func saveImage() {
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

    // Show success feedback
    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    impactFeedback.impactOccurred()

    // Optional callback
    onSave?(image)
  }

  private func shareImage() {
    let activityViewController = UIActivityViewController(
      activityItems: [image],
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
    onShare?(image)
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
  SwiftUIPhotoPreviewView(
    image: UIImage(systemName: "photo.fill")!,
    caption: .constant("Sample caption"),
    isPresented: .constant(true),
    onSend: { _, _ in }
  )
}
