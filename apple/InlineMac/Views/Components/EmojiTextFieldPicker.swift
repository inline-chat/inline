import AppKit
import SwiftUI

struct EmojiTextFieldPicker: View {
  @Binding var emoji: String

  var size: CGFloat = 30
  var placeholderSystemImage = "face.smiling"
  var allowsClear = true
  var isDisabled = false
  var accessibilityLabel = "Emoji"

  @State private var pickerRequest = 0
  @State private var isHovering = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        pickerRequest += 1
      } label: {
        iconField
      }
      .buttonStyle(.plain)
      .disabled(isDisabled)
      .help(isDisabled ? "" : "Change icon")
      .accessibilityLabel(accessibilityLabel)

      EmojiPanelPicker(presentationRequest: $pickerRequest) { selectedEmoji in
        emoji = Self.normalizedEmoji(selectedEmoji)
      }
      .frame(width: 1, height: 1)
      .opacity(0)
      .accessibilityHidden(true)

      if showsClearButton {
        Button {
          emoji = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: max(12, size * 0.32), weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        }
        .buttonStyle(.plain)
        .offset(x: size * 0.22, y: -size * 0.22)
        .help("Remove icon")
        .accessibilityLabel("Remove icon")
      }
    }
    .frame(width: size, height: size)
    .onHover { isHovering = $0 }
  }

  private var iconField: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: 1)
        }

      if normalizedEmoji.isEmpty {
        Image(systemName: placeholderSystemImage)
          .font(.system(size: size * 0.42, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        Text(normalizedEmoji)
          .font(.system(size: size * 0.55))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
    }
    .frame(width: size, height: size)
    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .opacity(isDisabled ? 0.55 : 1)
  }

  private var normalizedEmoji: String {
    Self.normalizedEmoji(emoji)
  }

  private var showsClearButton: Bool {
    allowsClear && !isDisabled && isHovering && !normalizedEmoji.isEmpty
  }

  private var borderColor: Color {
    if isDisabled {
      return Color.secondary.opacity(0.08)
    }
    return isHovering ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18)
  }

  private var cornerRadius: CGFloat {
    max(6, size * 0.22)
  }

  private static func normalizedEmoji(_ emoji: String) -> String {
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "" }
    return String(first)
  }
}
