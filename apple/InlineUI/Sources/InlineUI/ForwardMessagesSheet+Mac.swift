import InlineKit
import SwiftUI

#if os(macOS)
import AppKit

struct MacForwardMessagesSheetView: View {
  @Bindable var model: ForwardMessagesSheetModel
  let onClose: () -> Void
  let onToggleSelectionMode: () -> Void
  let onSend: () -> Void
  let onActivateDestination: (ForwardMessagesDestination) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            if model.filteredDestinations.isEmpty {
              emptyState
            } else {
              ForEach(model.filteredDestinations) { destination in
                MacForwardDestinationRow(
                  destination: destination,
                  isSelecting: model.isSelecting,
                  isSelected: model.isSelected(destination),
                  isHighlighted: model.isHighlighted(destination)
                ) {
                  onActivateDestination(destination)
                }
                .id(destination.id)
              }
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
        }
        .onChange(of: model.highlightedDestinationId) { _, id in
          guard let id else { return }
          proxy.scrollTo(id, anchor: .center)
        }
      }
      .disabled(model.isSending)
    }
  }

  private var header: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        closeButton

        Spacer(minLength: 0)

        HStack(spacing: 8) {
          if model.shouldShowSendButton {
            actionButton("Send", systemImage: "paperplane.fill", prominent: true) {
              onSend()
            }
          }

          if model.supportsMultiSelect {
            actionButton(
              model.isSelecting ? "Cancel" : "Select",
              systemImage: model.isSelecting ? "xmark.circle" : "checkmark.circle"
            ) {
              onToggleSelectionMode()
            }
          }
        }
      }
      .overlay {
        Text(model.navigationTitle)
          .font(.headline)
          .lineLimit(1)
          .allowsHitTesting(false)
      }

      NativeSearchField(
        text: $model.searchText,
        isFocused: $model.isSearchFocused,
        placeholder: "Search chats"
      )
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Search chats")
      .disabled(model.isSending)
    }
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 28, height: 28)
    }
    .labelStyle(.iconOnly)
    .buttonBorderShape(.circle)
    .controlSize(.regular)
    .modifier(MacCloseButtonStyle())
    .foregroundStyle(.secondary)
    .help("Close")
  }

  @ViewBuilder
  private func actionButton(
    _ title: String,
    systemImage: String,
    prominent: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button(action: action) {
      Label(title, systemImage: systemImage)
    }
    .disabled(model.isSending)
    .buttonBorderShape(.capsule)

    if #available(macOS 26.0, *) {
      if prominent {
        button
          .buttonStyle(.glassProminent)
          .controlSize(.regular)
      } else {
        button
          .buttonStyle(.glass)
          .controlSize(.regular)
      }
    } else {
      if prominent {
        button
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
      } else {
        button
          .buttonStyle(.bordered)
          .controlSize(.regular)
      }
    }
  }

  private var emptyState: some View {
    Text(model.searchText.isEmpty ? "No chats available" : "No chats found")
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
  }
}

private struct MacForwardDestinationRow: View, Equatable {
  let destination: ForwardMessagesDestination
  let isSelecting: Bool
  let isSelected: Bool
  let isHighlighted: Bool
  let onActivate: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false
  @State private var isPressing = false

  private static let rowHeight: CGFloat = 34
  private static let iconSize: CGFloat = 22
  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let replyTitleFont: Font = .system(size: 12, weight: .regular)
  private static let parentTitleFont: Font = .system(size: 10, weight: .regular)
  private static let subtitleFont: Font = .system(size: 11)
  private static let unreadDotSize: CGFloat = 6
  private static let radius: CGFloat = 7

  nonisolated static func == (lhs: MacForwardDestinationRow, rhs: MacForwardDestinationRow) -> Bool {
    lhs.destination == rhs.destination
      && lhs.isSelecting == rhs.isSelecting
      && lhs.isSelected == rhs.isSelected
      && lhs.isHighlighted == rhs.isHighlighted
  }

  var body: some View {
    Button(action: onActivate) {
      HStack(spacing: 0) {
        if isSelecting {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 22)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
        }

        ForwardMessagesAvatarView(
          avatar: destination.avatar,
          size: Self.iconSize,
          shape: .roundedSquare
        )
        .equatable()
        .padding(.trailing, 8)

        VStack(alignment: .leading, spacing: 1) {
          titleBlock

          if shouldShowPreview {
            Text(destination.preview)
              .font(Self.subtitleFont)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: Self.rowHeight)
      .padding(.horizontal, 6)
      .contentShape(.interaction, .rect(cornerRadius: Self.radius))
      .background(background)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .simultaneousGesture(pressGesture)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var titleBlock: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        if let parentTitle = destination.parentTitle {
          Text(parentTitle)
            .font(Self.parentTitleFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text(destination.title)
          .font(destination.parentTitle == nil ? Self.titleFont : Self.replyTitleFont)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if destination.unread {
        ForwardMessagesUnreadDot(size: Self.unreadDotSize)
          .frame(width: 14, alignment: .center)
      } else if destination.pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 14, alignment: .center)
          .accessibilityLabel("Pinned")
      }
    }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color.accentColor.opacity(isHighlighted ? 0.24 : 0.16)
    }

    if isHighlighted || isPressing {
      return colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.07)
    }

    if isHovered {
      return colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    }

    return .clear
  }

  private var shouldShowPreview: Bool {
    destination.parentTitle == nil && destination.preview.isEmpty == false
  }

  private var accessibilityTitle: String {
    if let parentTitle = destination.parentTitle {
      return "\(parentTitle), \(destination.title)"
    }
    return destination.title
  }

  private var pressGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        isPressing = true
      }
      .onEnded { _ in
        isPressing = false
      }
  }
}

private struct NativeSearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let placeholder: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let searchField = NSSearchField(frame: .zero)
    searchField.delegate = context.coordinator
    searchField.placeholderString = placeholder
    searchField.sendsSearchStringImmediately = true
    searchField.target = context.coordinator
    searchField.action = #selector(Coordinator.submit)
    searchField.controlSize = .large
    return searchField
  }

  func updateNSView(_ searchField: NSSearchField, context: Context) {
    if searchField.stringValue != text {
      searchField.stringValue = text
    }
    if searchField.placeholderString != placeholder {
      searchField.placeholderString = placeholder
    }

    if isFocused, searchField.window?.firstResponder !== searchField.currentEditor() {
      searchField.window?.makeFirstResponder(searchField)
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    @Binding private var text: String
    @Binding private var isFocused: Bool

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      isFocused = false
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let searchField = notification.object as? NSSearchField else { return }
      if text != searchField.stringValue {
        text = searchField.stringValue
      }
    }

    @objc func submit() {}
  }
}

private struct MacCloseButtonStyle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .buttonStyle(.glass)
    } else {
      content
        .buttonStyle(.bordered)
    }
  }
}
#endif
