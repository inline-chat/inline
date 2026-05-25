import AppKit
import SwiftUI

struct EmojiTextFieldPicker<Label: View>: View {
  @Binding var emoji: String

  var allowsClear = true
  var isDisabled = false
  var accessibilityLabel = "Emoji"
  var targetSize: CGSize

  @State private var pickerRequest = 0
  @State private var isHovering = false

  private let label: (String, Bool, Bool) -> Label

  init(
    emoji: Binding<String>,
    targetSize: CGSize,
    allowsClear: Bool = true,
    isDisabled: Bool = false,
    accessibilityLabel: String = "Emoji",
    @ViewBuilder label: @escaping (String, Bool, Bool) -> Label
  ) {
    _emoji = emoji
    self.targetSize = targetSize
    self.allowsClear = allowsClear
    self.isDisabled = isDisabled
    self.accessibilityLabel = accessibilityLabel
    self.label = label
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        pickerRequest += 1
      } label: {
        label(normalizedEmoji, isHovering, isDisabled)
          .frame(width: targetSize.width, height: targetSize.height)
      }
      .buttonStyle(.plain)
      .focusable(false)
      .disabled(isDisabled)
      .help(isDisabled ? "" : "Change icon")
      .accessibilityLabel(accessibilityLabel)

      EmojiPanelPicker(presentationRequest: $pickerRequest) { selectedEmoji in
        emoji = Self.normalizedEmoji(selectedEmoji)
      }
      .frame(width: targetSize.width, height: targetSize.height)
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      if showsClearButton {
        Button {
          emoji = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: clearButtonSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .offset(x: clearButtonOffset, y: -clearButtonOffset)
        .help("Remove icon")
        .accessibilityLabel("Remove icon")
      }
    }
    .frame(width: targetSize.width, height: targetSize.height)
    .onHover { isHovering = $0 }
  }

  private var normalizedEmoji: String {
    Self.normalizedEmoji(emoji)
  }

  private var showsClearButton: Bool {
    allowsClear && !isDisabled && isHovering && !normalizedEmoji.isEmpty
  }

  private var clearButtonSize: CGFloat {
    min(18, max(12, min(targetSize.width, targetSize.height) * 0.32))
  }

  private var clearButtonOffset: CGFloat {
    min(8, min(targetSize.width, targetSize.height) * 0.22)
  }

  private static func normalizedEmoji(_ emoji: String) -> String {
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "" }
    return String(first)
  }
}

extension EmojiTextFieldPicker where Label == DefaultEmojiTextFieldPickerLabel {
  init(
    emoji: Binding<String>,
    size: CGFloat = 30,
    placeholderSystemImage: String = "face.smiling",
    allowsClear: Bool = true,
    isDisabled: Bool = false,
    accessibilityLabel: String = "Emoji"
  ) {
    self.init(
      emoji: emoji,
      targetSize: CGSize(width: size, height: size),
      allowsClear: allowsClear,
      isDisabled: isDisabled,
      accessibilityLabel: accessibilityLabel
    ) { emoji, isHovering, isDisabled in
      DefaultEmojiTextFieldPickerLabel(
        emoji: emoji,
        size: size,
        placeholderSystemImage: placeholderSystemImage,
        isHovering: isHovering,
        isDisabled: isDisabled
      )
    }
  }
}

struct DefaultEmojiTextFieldPickerLabel: View {
  let emoji: String
  let size: CGFloat
  let placeholderSystemImage: String
  let isHovering: Bool
  let isDisabled: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: 1)
        }

      if emoji.isEmpty {
        Image(systemName: placeholderSystemImage)
          .font(.system(size: size * 0.42, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        Text(emoji)
          .font(.system(size: size * 0.55))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
    }
    .frame(width: size, height: size)
    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .opacity(isDisabled ? 0.55 : 1)
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
}
