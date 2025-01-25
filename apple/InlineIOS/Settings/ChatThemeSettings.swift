// ChatThemeSettings.swift
import InlineKit
import InlineUI
import SwiftUI

struct ThemeSection: View {
  var body: some View {
    List {
      ChatThemeSettings()
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "appearance", placement: .principal) {
        HStack {
          Image(systemName: "paintbrush.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Appearance")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }
}

struct ChatThemeSettings: View {
  @State private var accentColor: UIColor = ColorManager.shared.selectedColor

  var body: some View {
    Section(header: Text("Accent Color")) {
      VStack(alignment: .leading, spacing: 16) {
        MessagePreview(accentColor: accentColor)
          .background(Color(.systemGray6).opacity(0.5))
          .cornerRadius(16)

        ThemeColorGrid(selectedColor: $accentColor)
      }
      .padding(.vertical, 12)
      .animation(.spring(response: 0.35, dampingFraction: 0.5), value: accentColor)
    }
  }
}

struct ThemeColorGrid: View {
  @Binding var selectedColor: UIColor

  private let gridColumns = [
    GridItem(
      .adaptive(minimum: Theme.Settings.picker.minWidth),
      spacing: Theme.Settings.picker.spacing
    ),
  ]

  var body: some View {
    LazyVGrid(columns: gridColumns, spacing: Theme.Settings.picker.spacing) {
      ForEach(ColorManager.shared.availableColors, id: \.self) { themeColor in
        ThemeColorButton(
          color: themeColor,
          isSelected: themeColor == selectedColor,
          selectedColor: selectedColor
        ) {
          updateThemeColor(themeColor)
        }
      }
    }
  }

  private func updateThemeColor(_ color: UIColor) {
    withAnimation {
      selectedColor = color
      ColorManager.shared.saveColor(color)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
  }
}

struct ThemeColorButton: View {
  let color: UIColor
  let isSelected: Bool
  let selectedColor: UIColor
  let action: () -> Void

  var body: some View {
    ZStack {
      Circle()
        .fill(Color(uiColor: color))
        .frame(
          width: Theme.Settings.picker.buttonSize,
          height: Theme.Settings.picker.buttonSize
        )
        .scaleEffect(isSelected ? 1.1 : 1)

      Circle()
        .stroke(Color(uiColor: selectedColor), lineWidth: isSelected ? 2 : 0)
        .frame(
          width: Theme.Settings.picker.borderSize,
          height: Theme.Settings.picker.borderSize
        )
        .opacity(isSelected ? 1 : 0)
    }
    .buttonStyle(PlainButtonStyle())
    .onTapGesture(perform: action)
    .animation(.spring(response: 0.35, dampingFraction: 0.5), value: isSelected)
  }
}

struct MessagePreview: View {
  let accentColor: UIColor

  var body: some View {
    VStack(spacing: 12) {
      outgoingMessageBubble
      incomingMessageBubble
    }
    .padding()
  }

  private var outgoingMessageBubble: some View {
    HStack {
      Spacer()
      Text("Hey there! This is how your messages will look")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: accentColor))
        .foregroundColor(.white)
        .cornerRadius(16)
        .padding(.trailing, 8)
    }
  }

  private var incomingMessageBubble: some View {
    HStack {
      Text("This is a reply message")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(16)
        .padding(.leading, 8)
      Spacer()
    }
  }
}

#Preview("Theme Settings") {
  ChatThemeSettings()
    .padding()
}
