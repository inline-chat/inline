import GRDB
import Foundation
import InlineKit
import Observation
import Translation

private struct HomeTranslationMessageKey: Hashable, Sendable {
  let chatID: Int64
  let messageID: Int64
}

@MainActor
@Observable
final class ExperimentalHomeTranslationCoordinator {
  private static let batchLimit = 24
  private static let visibilityDebounce: Duration = .milliseconds(75)

  @ObservationIgnored private let core = Core()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var visibilityTask: Task<Void, Never>?
  @ObservationIgnored private var latestPresentation = ChatListPresentation.empty
  @ObservationIgnored private var latestCurrentPeers = Set<Peer>()
  @ObservationIgnored private var visiblePeers: [Peer] = []
  @ObservationIgnored private var visiblePeerCounts: [Peer: Int] = [:]
  @ObservationIgnored private var generation: UInt64 = 0

  func process(
    presentation: ChatListPresentation,
    currentPeers: Set<Peer>
  ) {
    latestPresentation = presentation
    latestCurrentPeers = currentPeers
    startProcess()
  }

  func rowVisibilityChanged(peer: Peer, isVisible: Bool) {
    if isVisible {
      let previousCount = visiblePeerCounts[peer, default: 0]
      visiblePeerCounts[peer] = previousCount + 1
      if previousCount == 0 {
        visiblePeers.append(peer)
      }
    } else if let count = visiblePeerCounts[peer], count > 1 {
      visiblePeerCounts[peer] = count - 1
    } else {
      visiblePeerCounts.removeValue(forKey: peer)
      visiblePeers.removeAll { $0 == peer }
    }

    visibilityTask?.cancel()
    visibilityTask = Task { [weak self] in
      try? await Task.sleep(for: Self.visibilityDebounce)
      guard !Task.isCancelled else { return }
      self?.startProcess()
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
      // Reprocess on both transitions. Disabling must cancel stale reserved work;
      // enabling must make the unchanged signature eligible immediately.
      _ = isEnabled
      process(presentation: presentation, currentPeers: currentPeers)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
    visibilityTask?.cancel()
    visibilityTask = nil
    visiblePeers.removeAll()
    visiblePeerCounts.removeAll()
  }

  private func startProcess() {
    generation &+= 1
    let processGeneration = generation
    let presentation = latestPresentation
    let currentPeers = latestCurrentPeers
    let prioritizedPeers = visiblePeers
    let batchLimit = Self.batchLimit

    task?.cancel()
    retryTask?.cancel()
    retryTask = nil
    let worker = Task.detached(priority: .utility) { [core] in
      let snapshots = presentation.allChats + presentation.archived
      let enabledPeers = Set(snapshots.lazy.compactMap { snapshot in
        TranslationState.shared.isTranslationEnabled(for: snapshot.peer)
          ? snapshot.peer
          : nil
      })

      await core.beginGeneration(processGeneration)
      let candidates = await core.reserve(
        snapshots: snapshots,
        prioritizedPeers: prioritizedPeers,
        enabledPeers: enabledPeers,
        excluding: currentPeers,
        generation: processGeneration,
        limit: batchLimit
      )
      guard !candidates.isEmpty else {
        return await core.nextRetryDate()
      }

      do {
        try Task.checkCancellation()
        let messageIDs = Set(candidates.map(\.messageID))
        let messages = try await AppDatabase.shared.reader.read { db in
          try FullMessage.queryRequest()
            .filter(messageIDs.contains(Column("messageId")))
            .fetchAll(db)
        }
        try Task.checkCancellation()

        let messagesByKey = Dictionary(
          messages.map {
            (HomeTranslationMessageKey(chatID: $0.chatId, messageID: $0.message.messageId), $0)
          },
          uniquingKeysWith: { first, _ in first }
        )
        let grouped = Dictionary(grouping: candidates) { $0.peer }
        var missing: [HomeTranslationCandidate] = []

        for (peer, peerCandidates) in grouped {
          try Task.checkCancellation()
          let peerMessages = peerCandidates.compactMap { candidate in
            messagesByKey[HomeTranslationMessageKey(
              chatID: candidate.chatID,
              messageID: candidate.messageID
            )]
          }
          let peerMessageKeys = Set(peerMessages.map {
            HomeTranslationMessageKey(chatID: $0.chatId, messageID: $0.message.messageId)
          })
          let foundCandidates = peerCandidates.filter {
            peerMessageKeys.contains(HomeTranslationMessageKey(
              chatID: $0.chatID,
              messageID: $0.messageID
            ))
          }
          missing.append(contentsOf: peerCandidates.filter { !foundCandidates.contains($0) })

          guard !peerMessages.isEmpty else { continue }
          TranslationViewModel.translateMessages(for: peer, messages: peerMessages)
          await core.finish(foundCandidates, outcome: .dispatched)
        }

        await core.finish(missing, outcome: .failed)
      } catch is CancellationError {
        await core.finish(candidates, outcome: .cancelled)
      } catch {
        await core.finish(candidates, outcome: .failed)
      }

      return await core.nextRetryDate()
    }

    task = Task { [weak self] in
      let retryDate = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, let retryDate else { return }
      self?.scheduleRetry(at: retryDate)
    }
  }

  private func scheduleRetry(at retryDate: Date) {
    let delay = max(0, retryDate.timeIntervalSinceNow)
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled else { return }
      self?.startProcess()
    }
  }

  private actor Core {
    private var tracker = HomeTranslationWorkTracker()

    func beginGeneration(_ generation: UInt64) {
      tracker.beginGeneration(generation)
    }

    func reserve(
      snapshots: [ChatListItemSnapshot],
      prioritizedPeers: [Peer],
      enabledPeers: Set<Peer>,
      excluding currentPeers: Set<Peer>,
      generation: UInt64,
      limit: Int
    ) -> [HomeTranslationCandidate] {
      tracker.reserve(
        snapshots: snapshots,
        prioritizedPeers: prioritizedPeers,
        enabledPeers: enabledPeers,
        excluding: currentPeers,
        generation: generation,
        limit: limit
      )
    }

    func finish(
      _ candidates: [HomeTranslationCandidate],
      outcome: HomeTranslationWorkOutcome
    ) {
      tracker.finish(candidates, outcome: outcome)
    }

    func reset(peer: Peer) {
      tracker.reset(peer: peer)
    }

    func nextRetryDate() -> Date? {
      tracker.nextRetryDate()
    }
  }
}
