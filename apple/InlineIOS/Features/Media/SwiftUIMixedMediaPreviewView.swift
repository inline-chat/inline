import AVKit
import SwiftUI
import UIKit

enum MixedMediaPreviewItem: Identifiable {
  case photo(id: UUID, image: UIImage)
  case video(id: UUID, url: URL)

  var id: UUID {
    switch self {
      case let .photo(id, _): id
      case let .video(id, _): id
    }
  }

  var videoURL: URL? {
    guard case let .video(_, url) = self else { return nil }
    return url
  }
}

final class MixedMediaPreviewViewModel: ObservableObject {
  @Published var caption: String = ""
  @Published var isPresented: Bool = false
}

struct SwiftUIMixedMediaPreviewView: View {
  let items: [MixedMediaPreviewItem]
  @Binding var caption: String
  @Binding var isPresented: Bool
  let onSend: (String) -> Void

  @State private var selectedItemID: UUID?
  @FocusState private var isCaptionFocused: Bool
  @State private var keyboardHeight: CGFloat = 0

  var body: some View {
    ZStack {
      Color(.systemBackground)
        .ignoresSafeArea()

      TabView(selection: $selectedItemID) {
        ForEach(items) { item in
          mediaView(for: item)
            .tag(item.id)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
      .onAppear {
        if selectedItemID == nil {
          selectedItemID = items.first?.id
        }
        setupKeyboardObservers()
      }
      .onDisappear {
        removeKeyboardObservers()
      }
    }
    .overlay(alignment: .topLeading) {
      Button {
        withAnimation(.easeOut(duration: 0.2)) {
          isPresented = false
        }
      } label: {
        Circle()
          .fill(Color(.secondarySystemBackground))
          .frame(width: 44, height: 44)
          .overlay {
            Image(systemName: "xmark")
              .font(.callout)
              .foregroundColor(ThemeManager.shared.textPrimaryColor)
          }
      }
      .padding(.leading, 16)
      .padding(.top, 16)
    }
    .overlay(alignment: .topTrailing) {
      Text(items.count == 1 ? "1 item" : "\(items.count) items")
        .font(.body)
        .foregroundColor(ThemeManager.shared.textPrimaryColor)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
          Capsule()
            .fill(ThemeManager.shared.surfaceBackgroundColor)
        )
        .padding(.trailing, 16)
        .padding(.top, 16)
    }
    .overlay(alignment: .bottom) {
      HStack(alignment: .bottom, spacing: 12) {
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
          .submitLabel(.done)
          .onSubmit { isCaptionFocused = false }

        Button {
          if isCaptionFocused {
            isCaptionFocused = false
          } else {
            onSend(caption)
          }
        } label: {
          Image(systemName: isCaptionFocused ? "checkmark" : "arrow.up")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(
              Circle()
                .fill(ThemeManager.shared.accentColor)
            )
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, keyboardHeight > 0 ? 8 : 20)
    }
    .statusBarHidden()
  }

  @ViewBuilder
  private func mediaView(for item: MixedMediaPreviewItem) -> some View {
    switch item {
      case let .photo(_, image):
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .ignoresSafeArea()
      case let .video(_, url):
        MixedMediaVideoItem(url: url)
          .ignoresSafeArea()
    }
  }

  private func setupKeyboardObservers() {
    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { notification in
      if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
        withAnimation(.easeInOut(duration: 0.3)) {
          keyboardHeight = keyboardFrame.height
        }
      }
    }

    NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main
    ) { _ in
      withAnimation(.easeInOut(duration: 0.3)) {
        keyboardHeight = 0
      }
    }
  }

  private func removeKeyboardObservers() {
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
  }
}

private struct MixedMediaVideoItem: View {
  let url: URL
  @State private var player: AVPlayer = .init()

  var body: some View {
    VideoPlayer(player: player)
      .onAppear {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
      }
      .onDisappear {
        player.pause()
        player.replaceCurrentItem(with: nil)
      }
  }
}
