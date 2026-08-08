import GRDB
import InlineKit
import Observation
import Translation

@MainActor
@Observable
final class ExperimentalHomeTranslationCoordinator {
  @ObservationIgnored private let core = Core()
  @ObservationIgnored private var task: Task<Void, Never>?

  func process(
    presentation: ChatListPresentation,
    currentPeers: Set<Peer>
  ) {
    task?.cancel()
    task = Task.detached(priority: .utility) { [core] in
      let candidates = await core.candidates(
        from: presentation,
        excluding: currentPeers
      )
      guard !Task.isCancelled, !candidates.isEmpty else { return }

      let messages: [FullMessage]
      do {
        messages = try await AppDatabase.shared.reader.read { db in
          try candidates.compactMap { candidate in
            guard let messageID = candidate.contentSignature.messageID else { return nil }
            return try FullMessage.queryRequest()
              .filter(Column("messageId") == messageID)
              .filter(Column("chatId") == candidate.chatID)
              .fetchOne(db)
          }
        }
      } catch {
        return
      }

      for message in messages {
        guard !Task.isCancelled else { return }
        TranslationViewModel.translateMessages(
          for: message.peerId,
          messages: [message]
        )
      }
    }
  }

  func translationStateChanged(
    peer: Peer,
    isEnabled: Bool,
    presentation: ChatListPresentation,
    currentPeers: Set<Peer>
  ) {
    Task { [core] in
      await core.reset(peer: peer)
      guard isEnabled else { return }
      process(presentation: presentation, currentPeers: currentPeers)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  private actor Core {
    private var processedSignatures: [Peer: ChatListContentSignature] = [:]

    func candidates(
      from presentation: ChatListPresentation,
      excluding currentPeers: Set<Peer>
    ) -> [ChatListItemSnapshot] {
      guard !Task.isCancelled else { return [] }
      let snapshots = presentation.allChats + presentation.archived
      guard !Task.isCancelled else { return [] }
      let visiblePeers = Set(snapshots.map(\.peer))
      processedSignatures = processedSignatures.filter { visiblePeers.contains($0.key) }

      var candidates: [ChatListItemSnapshot] = []
      for snapshot in snapshots {
        guard !Task.isCancelled else { return [] }
        guard !currentPeers.contains(snapshot.peer),
              snapshot.contentSignature.messageID != nil,
              TranslationState.shared.isTranslationEnabled(for: snapshot.peer),
              processedSignatures[snapshot.peer] != snapshot.contentSignature
        else { continue }

        processedSignatures[snapshot.peer] = snapshot.contentSignature
        candidates.append(snapshot)
      }
      return candidates
    }

    func reset(peer: Peer) {
      processedSignatures.removeValue(forKey: peer)
    }
  }
}
