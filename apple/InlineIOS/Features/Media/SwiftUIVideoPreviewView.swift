import AVFoundation
import AVKit
import SwiftUI

class VideoPreviewViewModel: ObservableObject {
  @Published var caption: String = ""
  @Published var isPresented: Bool = false
}

struct SwiftUIVideoPreviewView: View {
  let videoURL: URL
  let totalVideos: Int
  @Binding var caption: String
  @Binding var isPresented: Bool
  let onSend: (String) -> Void

  @State private var player: AVPlayer = .init()
  @State private var keyboardHeight: CGFloat = 0
  @State private var durationText: String?

  @FocusState private var isCaptionFocused: Bool

  private let closeButtonSize: CGFloat = 44
  private let bottomContentPadding: CGFloat = 20
  private let bottomContentSpacing: CGFloat = 12
  private let animationDuration: TimeInterval = 0.3

  var body: some View {
    ZStack {
      Color(.systemBackground)
        .ignoresSafeArea()

      VideoPlayer(player: player)
        .ignoresSafeArea()
    }
    .overlay(alignment: .topLeading) {
      closeButton
        .padding(.leading, 16)
        .padding(.top, 16)
    }
    .overlay(alignment: .topTrailing) {
      HStack(spacing: 8) {
        if totalVideos > 1 {
          counterPill
        }

        if let durationText {
          durationPill(durationText)
        }
      }
      .padding(.trailing, 16)
      .padding(.top, 16)
    }
    .overlay(alignment: .bottom) {
      bottomContent
    }
    .statusBarHidden()
    .onAppear {
      configurePlayer()
      setupKeyboardObservers()
      loadDurationText()
    }
    .onDisappear {
      removeKeyboardObservers()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

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
          .glassEffect(.regular, in: Circle())
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
    .buttonStyle(VideoScaleButtonStyle())
  }

  private var counterPill: some View {
    Text(totalVideos == 1 ? "1 video" : "\(totalVideos) videos")
      .font(.body)
      .foregroundColor(ThemeManager.shared.textPrimaryColor)
      .padding(.horizontal, 12)
      .frame(height: closeButtonSize)
      .background {
        if #available(iOS 26.0, *) {
          Capsule()
            .fill(ThemeManager.shared.cardBackgroundColor)
            .glassEffect(.regular, in: Capsule())
        } else {
          Capsule()
            .fill(ThemeManager.shared.surfaceBackgroundColor)
        }
      }
  }

  private func durationPill(_ text: String) -> some View {
    Text(text)
      .font(.body.monospacedDigit())
      .foregroundColor(ThemeManager.shared.textPrimaryColor)
      .padding(.horizontal, 12)
      .frame(height: closeButtonSize)
      .background {
        if #available(iOS 26.0, *) {
          Capsule()
            .fill(ThemeManager.shared.cardBackgroundColor)
            .glassEffect(.regular, in: Capsule())
        } else {
          Capsule()
            .fill(ThemeManager.shared.surfaceBackgroundColor)
        }
      }
  }

  private var captionTextField: some View {
    TextField("Add a caption...", text: $caption, axis: .vertical)
      .focused($isCaptionFocused)
      .font(.system(size: 16))
      .foregroundColor(ThemeManager.shared.textPrimaryColor)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background {
        RoundedRectangle(cornerRadius: 20)
          .fill(Color(.systemBackground))
          .stroke(ThemeManager.shared.borderColor, lineWidth: 1)
      }
      .lineLimit(isCaptionFocused ? (1 ... 4) : (1 ... 1))
      .onSubmit {
        isCaptionFocused = false
      }
      .submitLabel(.done)
      .onTapGesture {
        if !isCaptionFocused {
          isCaptionFocused = true
        }
      }
  }

  private var sendButton: some View {
    Button(action: {
      if isCaptionFocused {
        isCaptionFocused = false
      } else {
        onSend(caption)
      }
    }) {
      Image(systemName: isCaptionFocused ? "checkmark" : "arrow.up")
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: 44, height: 44)
        .background(
          Circle()
            .fill(ThemeManager.shared.accentColor)
        )
    }
    .buttonStyle(VideoScaleButtonStyle())
  }

  private var bottomContent: some View {
    HStack(alignment: .bottom, spacing: bottomContentSpacing) {
      captionTextField
      sendButton
    }
    .padding(.horizontal, bottomContentPadding)
    .padding(.bottom, keyboardHeight > 0 ? 8 : bottomContentPadding)
  }

  private func configurePlayer() {
    player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
    player.play()
  }

  private func loadDurationText() {
    let asset = AVURLAsset(url: videoURL)
    let duration = asset.duration.seconds

    guard duration.isFinite, duration > 0 else {
      durationText = nil
      return
    }

    durationText = Self.formatDuration(duration)
  }

  private static func formatDuration(_ duration: Double) -> String {
    let totalSeconds = Int(duration.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%d:%02d", minutes, seconds)
  }

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

private struct VideoScaleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}
