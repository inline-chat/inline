import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

public struct VoiceMemoMessage: Identifiable, Equatable, Sendable {
  public var id: Int64 { message.messageId }
  public let message: Message
  public let voice: Client_MessageVoiceContent
}

public struct VoiceMemoMessageGroup {
  public let date: Date
  public let messages: [VoiceMemoMessage]
}

@MainActor
public final class ChatVoiceMemosViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let peer: Peer
  private let db: AppDatabase

  @Published public private(set) var voiceMemoMessages: [VoiceMemoMessage] = []

  private var messagesCancellable: AnyCancellable?
  private var isLoading = false
  private var hasMore = true
  private var nextOffsetId: Int64?
  private var hasStarted = false

  private let pageSize: Int32 = 50
  private let loadMoreTriggerWindow = 8

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    self.db = db
    self.chatId = chatId
    self.peer = peer
    fetchVoiceMemoMessages()
  }

  private func fetchVoiceMemoMessages() {
    db.warnIfInMemoryDatabaseForObservation("ChatVoiceMemosViewModel.voiceMemoMessages")
    messagesCancellable = ValueObservation
      .tracking { [chatId] db in
        try Message
          .filter(Message.Columns.chatId == chatId)
          .filter(Message.Columns.contentPayload != nil)
          .order(Message.Columns.date.desc)
          .fetchAll(db)
          .compactMap { message -> VoiceMemoMessage? in
            guard let voice = message.voiceContent else { return nil }
            return VoiceMemoMessage(message: message, voice: voice)
          }
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [chatId] completion in
          if case let .failure(error) = completion {
            Log.shared.error("Failed to load chat voice memos for chat \(chatId)", error: error)
          }
        },
        receiveValue: { [weak self] messages in
          self?.voiceMemoMessages = messages
        }
      )
  }

  public var groupedVoiceMemoMessages: [VoiceMemoMessageGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: voiceMemoMessages) { message in
      calendar.startOfDay(for: message.message.date)
    }

    return grouped.map { date, messages in
      VoiceMemoMessageGroup(date: date, messages: messages.sorted { $0.message.date > $1.message.date })
    }.sorted { $0.date > $1.date }
  }

  public func loadInitial() async {
    guard !hasStarted else { return }
    hasStarted = true
    await loadMore(reset: true)
  }

  public func loadMoreIfNeeded(currentMessageId: Int64) async {
    guard Self.shouldLoadMore(
      currentMessageId: currentMessageId,
      loadedMessageIds: voiceMemoMessages.map(\.message.messageId),
      triggerWindow: loadMoreTriggerWindow
    ) else { return }
    await loadMore(reset: false)
  }

  nonisolated static func shouldLoadMore(
    currentMessageId: Int64,
    loadedMessageIds: [Int64],
    triggerWindow: Int
  ) -> Bool {
    guard triggerWindow > 0, !loadedMessageIds.isEmpty else { return false }
    let dedupedIds = Array(Set(loadedMessageIds))
    let oldestToNewest = dedupedIds.sorted()
    let triggerCount = min(triggerWindow, oldestToNewest.count)
    return oldestToNewest.prefix(triggerCount).contains(currentMessageId)
  }

  private func loadMore(reset: Bool) async {
    guard !isLoading else { return }

    if reset {
      nextOffsetId = nil
      hasMore = true
    }

    guard hasMore else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      let result = try await Api.realtime.send(
        .searchMessages(
          peer: peer,
          queries: [],
          offsetID: nextOffsetId,
          limit: pageSize,
          filter: .filterVoiceMemos
        )
      )

      guard case let .searchMessages(response) = result else {
        Log.shared.error("Unexpected searchMessages response for voice memos in chat \(chatId)")
        return
      }

      guard !response.messages.isEmpty else {
        hasMore = false
        return
      }

      if let lastMessageId = response.messages.last?.id {
        nextOffsetId = lastMessageId
      }

      if response.messages.count < pageSize {
        hasMore = false
      }
    } catch {
      Log.shared.error("Failed to load voice memo messages", error: error)
    }
  }
}
