#if os(macOS)
import InlineKit
import SwiftUI

/// A macOS experiment that sends from the picker without changing the source route or draft.
public struct QuickForwardMessagesSheet: View {
  public typealias CommentHandler = @MainActor (HomeChatItem, String) async throws -> Void
  public typealias ForwardHandler = @MainActor (
    HomeChatItem, ForwardMessagesSheet.ForwardMessagesSelection
  ) async throws -> Void

  private let sendComment: CommentHandler
  private let forward: ForwardHandler
  private let onComplete: (Int) -> Void
  private let preview: String

  @Environment(\.dismiss) private var dismiss
  @State private var model: ForwardMessagesSheetModel
  @State private var delivery = QuickForwardDelivery()
  @State private var comment = ""
  @State private var sendingDestinations: [ForwardMessagesDestination]?
  @State private var sendTask: Task<Void, Never>?
  @FocusState private var searchFocused: Bool

  public init(
    messages: [FullMessage],
    database: AppDatabase,
    sendComment: @escaping CommentHandler,
    forward: @escaping ForwardHandler,
    onComplete: @escaping (Int) -> Void
  ) {
    self.sendComment = sendComment
    self.forward = forward
    self.onComplete = onComplete
    preview = messages.first?.message.text ?? ""
    _model = State(initialValue: ForwardMessagesSheetModel(
      messages: messages,
      database: database,
      supportsMultiSelect: true
    ))
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 14, weight: .semibold))
          Text(preview.isEmpty ? "Choose chats below" : preview)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Close", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
          .buttonStyle(QuickForwardCloseStyle())
          .disabled(delivery.isSending)
          .help("Close")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        TextField("Search chats", text: $model.searchText)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .focused($searchFocused)
          .onSubmit { toggleHighlighted() }
          .onKeyPress(.downArrow) { moveHighlight(1) }
          .onKeyPress(.upArrow) { moveHighlight(-1) }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      .disabled(delivery.hasStarted)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            if !model.hasLoadedDestinations {
              ProgressView().padding()
            } else if model.filteredDestinations.isEmpty {
              Text("No chats found").foregroundStyle(.secondary).padding()
            } else {
              ForEach(model.filteredDestinations) { destination in
                MacForwardDestinationRow(
                  destination: destination,
                  isSelecting: true,
                  isSelected: model.isSelected(destination),
                  isHighlighted: model.isHighlighted(destination),
                  selectionStyle: .trailingCheckmark
                ) {
                  model.highlightedDestinationId = destination.id
                  model.toggleSelection(for: destination)
                }
                .id(destination.id)
              }
            }
          }
          .padding(8)
        }
        .onChange(of: model.highlightedDestinationId) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .disabled(delivery.hasStarted)

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        if !selectedDestinations.isEmpty {
          selectedRecipients
        }

        TextField("Add a comment…", text: $comment, axis: .vertical)
          .lineLimit(2 ... 4)
          .font(.system(size: 13))
          .textFieldStyle(.plain)
          .padding(.vertical, 8)
          .disabled(delivery.hasStarted)
          .accessibilityLabel("Optional comment")
          .accessibilityHint("Optional message sent before the forwarded messages")

        if let errorMessage = delivery.errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }

        HStack {
          Text(delivery.completedPeers.isEmpty ? "⌘ Return to send" : "Sent to \(delivery.completedPeers.count) chat(s)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          if delivery.isSending { ProgressView().controlSize(.small) }
          Button(action: send) {
            Label(delivery.errorMessage == nil ? sendTitle : "Retry Remaining", systemImage: "arrow.up")
          }
          .buttonStyle(QuickForwardSendStyle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(selectedDestinations.isEmpty || model.selection == nil || delivery.isSending)
        }
      }
      .padding(16)
    }
    .frame(width: 420, height: 520)
    .modifier(QuickForwardSurface())
    .presentationBackground(.clear)
    .interactiveDismissDisabled(delivery.isSending)
    .onExitCommand {
      guard !delivery.isSending else { return }
      if !model.searchText.isEmpty, !delivery.hasStarted { model.searchText = "" } else { dismiss() }
    }
    .onChange(of: model.filteredDestinations.map(\.id)) {
      model.syncHighlightedDestination()
    }
    .onDisappear { sendTask?.cancel() }
    .task {
      model.start()
      searchFocused = true
    }
  }

  private var title: String {
    let count = model.selection?.messageIds.count ?? 0
    return count == 1 ? "Forward Message" : "Forward \(count) Messages"
  }

  private var selectedDestinations: [ForwardMessagesDestination] {
    sendingDestinations ?? model.destinations.filter { model.isSelected($0) }
  }

  private var selectedRecipients: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(selectedDestinations) { destination in
          Button {
            model.toggleSelection(for: destination)
          } label: {
            HStack(spacing: 6) {
              Text(destination.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160)
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove \(destination.title)")
          .help(destination.title)
        }
      }
    }
    .frame(height: 24)
    .disabled(delivery.hasStarted)
    .accessibilityLabel("Selected recipients")
  }

  private var sendTitle: String {
    model.selectedCount == 0 ? "Send" : "Send to \(model.selectedCount) \(model.selectedCount == 1 ? "Chat" : "Chats")"
  }

  private func moveHighlight(_ offset: Int) -> KeyPress.Result {
    model.moveHighlightedDestination(by: offset)
    return .handled
  }

  private func toggleHighlighted() {
    guard !delivery.hasStarted, let destination = model.highlightedDestination() else { return }
    model.toggleSelection(for: destination)
  }

  private func send() {
    guard sendTask == nil, !delivery.isSending, let selection = model.selection else { return }
    let destinations = selectedDestinations
    let items = destinations.map(\.item)
    guard !items.isEmpty else { return }
    sendingDestinations = destinations
    let byPeer = Dictionary(items.map { ($0.peerId, $0) }, uniquingKeysWith: { first, _ in first })
    let peers = items.map(\.peerId)
    let comment = comment
    sendTask = Task { @MainActor in
      defer { sendTask = nil }
      let succeeded = await delivery.send(
        to: peers,
        comment: comment,
        sendComment: { peer, text in
          guard let item = byPeer[peer] else { return }
          try await sendComment(item, text)
        },
        forward: { peer in
          guard let item = byPeer[peer] else { return }
          try await forward(item, selection)
        }
      )
      if succeeded, !Task.isCancelled {
        onComplete(delivery.completedPeers.count)
        dismiss()
      }
    }
  }
}

private struct QuickForwardSurface: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: 16))
    } else {
      content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
  }
}

private struct QuickForwardSendStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .padding(.horizontal, 12)
      .frame(height: 28)
      .foregroundStyle(isEnabled ? Color.white : Color.secondary)
      .background(
        isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.06),
        in: Capsule()
      )
  }
}

private struct QuickForwardCloseStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
      .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Circle())
  }
}
#endif
