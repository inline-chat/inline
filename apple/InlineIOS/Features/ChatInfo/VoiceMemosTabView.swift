import Combine
import Foundation
import InlineKit
import InlineUI
import Observation
import SwiftUI

/// The Voice tab: month cards of voice messages, newest first.
///
/// Rows are static until played. `VoiceMessageBubble` observes the shared player, which
/// publishes on every playback tick and checks the file on disk in `body`, so only the
/// selected message gets one; every other row is two lines of text and a play glyph.
/// Tapping a row plays it inline, downloading first when needed.
@available(iOS 17.0, *)
struct VoiceMemosTabView: View {
  @ObservedObject var voiceMemosViewModel: ChatVoiceMemosViewModel
  let onShowInChat: (Message) -> Void

  @State private var model = ChatInfoResourceListModel<VoiceMemoMessage, ChatInfoResourceListItem<VoiceMemoMessage>>()
  private var selection: ChatInfoResourceVoiceSelection { .shared }

  var body: some View {
    let sections = model.cache.sections(
      for: voiceMemosViewModel.voiceMemoMessages,
      date: \.message.date,
      id: \.message.messageId
    ) { voiceMemo, placement in
      ChatInfoResourceListItem(id: voiceMemo.id, placement: placement, row: voiceMemo)
    }
    let current = selection.current

    LazyVStack(spacing: 0) {
      ForEach(sections) { section in
        Section {
          ForEach(section.items) { item in
            ChatInfoResourceVoiceRow(
              voiceMemo: item.row,
              isSelected: current == ChatInfoResourceVoiceSelection.Key(item.row.message),
              onShowInChat: onShowInChat
            )
            .equatable()
            .chatInfoResourceRow(item.placement.position)
            .onAppear { model.itemAppeared(item.placement.index, window: voiceMemosViewModel) }
          }
        } header: {
          ChatInfoResourceSectionHeader(title: section.title)
        }
      }

      ChatInfoResourceFooter(
        state: voiceMemosViewModel.loadState,
        rowCount: voiceMemosViewModel.voiceMemoMessages.count,
        empty: .init(systemImage: "waveform", message: "No voice messages yet"),
        onReachEnd: { model.pager.requestMore(voiceMemosViewModel) },
        retry: { model.pager.retry(voiceMemosViewModel) }
      )
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .task {
      #if DEBUG
      await ChatInfoResourceHarness.seedIfRequested()
      #endif
      await voiceMemosViewModel.loadInitial()
    }
    .onDisappear { voiceMemosViewModel.deactivate() }
  }
}

/// Which voice message the shared player has selected (playing, paused or downloading),
/// published only when the selection changes rather than on every playback tick.
@available(iOS 17.0, *)
@MainActor
@Observable
final class ChatInfoResourceVoiceSelection {
  struct Key: Hashable {
    let chatId: Int64
    let messageId: Int64

    init(chatId: Int64, messageId: Int64) {
      self.chatId = chatId
      self.messageId = messageId
    }

    init(_ message: Message) {
      self.init(chatId: message.chatId, messageId: message.messageId)
    }
  }

  static let shared = ChatInfoResourceVoiceSelection()

  private(set) var current: Key?
  @ObservationIgnored private var subscription: AnyCancellable?

  private init() {
    let player = SharedAudioPlayer.shared
    subscription = player.$state.map(\.item)
      .combineLatest(player.$loadingVoice.map { $0?.item })
      .map { playing, loading -> Key? in
        guard let item = loading ?? playing, item.kind == .voice else { return nil }
        return Key(chatId: item.chatId, messageId: item.messageId)
      }
      .removeDuplicates()
      .sink { [weak self] key in
        MainActor.assumeIsolated {
          self?.current = key
        }
      }
  }
}

@available(iOS 17.0, *)
private struct ChatInfoResourceVoiceRow: View, Equatable {
  let voiceMemo: VoiceMemoMessage
  let isSelected: Bool
  let onShowInChat: (Message) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.voiceMemo == rhs.voiceMemo && lhs.isSelected == rhs.isSelected
  }

  private var accent: Color {
    Color(ThemeManager.shared.selected.accent)
  }

  private var detailText: String {
    let date = ChatInfoResourceFormat.rowDate(voiceMemo.message.date)
    guard voiceMemo.voice.duration > 0 else { return date }
    return "\(ChatInfoResourceFormat.duration(Int(voiceMemo.voice.duration))) · \(date)"
  }

  var body: some View {
    Group {
      if isSelected {
        // The bubble owns play, pause, seek and download here; no row button around it.
        VStack(alignment: .leading, spacing: 6) {
          header(symbol: "waveform")
          VoiceMessageBubble(message: voiceMemo.message, outgoing: false, mode: .minimal, accentColor: accent)
            .padding(.leading, ChatInfoResourceMetrics.tileSize + ChatInfoResourceMetrics.tileSpacing)
        }
        .padding(.horizontal, ChatInfoResourceMetrics.rowHorizontalPadding)
        .padding(.vertical, ChatInfoResourceMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Button {
          SharedAudioPlayer.shared.requestVoicePlayback(for: voiceMemo.message)
        } label: {
          header(symbol: "play.fill")
            .padding(.horizontal, ChatInfoResourceMetrics.rowHorizontalPadding)
            .padding(.vertical, ChatInfoResourceMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatInfoResourceRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Voice message, \(detailText)"))
        .accessibilityHint("Plays the voice message")
        .accessibilityAddTraits(.isButton)
      }
    }
    .animation(.smooth(duration: 0.25), value: isSelected)
    .contextMenu {
      Button {
        onShowInChat(voiceMemo.message)
      } label: {
        Label("Show in Chat", systemImage: "text.bubble")
      }
    }
  }

  private func header(symbol: String) -> some View {
    HStack(spacing: ChatInfoResourceMetrics.tileSpacing) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(accent)
        .frame(width: ChatInfoResourceMetrics.tileSize, height: ChatInfoResourceMetrics.tileSize)
        .background(accent.opacity(0.14), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Voice message")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(detailText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
