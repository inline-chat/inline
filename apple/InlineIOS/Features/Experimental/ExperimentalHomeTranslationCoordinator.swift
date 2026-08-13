import Foundation
import GRDB
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

  @ObservationIgnored private let core = Core()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var latestPresentation = ChatListPresentation.empty
  @ObservationIgnored private var latestCurrentPeers = Set<Peer>()
  @ObservationIgnored private var generation: UInt64 = 0

  func process(
    presentation: ChatListPresentation,
    currentPeers: Set<Peer>
  ) {
    latestPresentation = presentation
    latestCurrentPeers = currentPeers
    startProcess()
  }

  func translationStateChanged(
    peer: Peer,
    isEnabled: Bool,
    presentation: ChatListPresentation,
    currentPeers: Set<Peer>
  ) {
    Task { [core] in
      await core.reset(peer: peer)
      // Reprocess both transitions. Disabling must cancel reserved work and
      // enabling must make an unchanged signature eligible immediately.
      _ = isEnabled
      process(presentation: presentation, currentPeers: currentPeers)
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
  }

  private func startProcess() {
    generation &+= 1
    let processGeneration = generation
    let presentation = latestPresentation
    let currentPeers = latestCurrentPeers
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
      let eligibleRetryPeers = enabledPeers
        .subtracting(currentPeers)
        .intersection(snapshots.lazy.compactMap { snapshot in
          snapshot.contentSignature.draftRevision == nil ? snapshot.peer : nil
        })

      await core.beginGeneration(processGeneration)
      let candidates = await core.reserve(
        snapshots: snapshots,
        enabledPeers: enabledPeers,
        excluding: currentPeers,
        generation: processGeneration,
        limit: batchLimit
      )
      guard !candidates.isEmpty else {
        return await core.nextRetryDate(eligiblePeers: eligibleRetryPeers)
      }

      do {
        try Task.checkCancellation()
        let messageIDs = Set(candidates.map(\.messageID))
        let chatIDs = Set(candidates.map(\.chatID))
        let messages = try await AppDatabase.shared.reader.read { db in
          try FullMessage.queryRequest()
            .filter(messageIDs.contains(Column("messageId")))
            .filter(chatIDs.contains(Column("chatId")))
            .fetchAll(db)
        }
        try Task.checkCancellation()

        let messagesByKey = Dictionary(
          messages.map {
            (HomeTranslationMessageKey(chatID: $0.chatId, messageID: $0.message.messageId), $0)
          },
          uniquingKeysWith: { first, _ in first }
        )
        let groupedCandidates = Dictionary(grouping: candidates, by: \.peer)
        var missingCandidates: [HomeTranslationCandidate] = []

        for (peer, peerCandidates) in groupedCandidates {
          try Task.checkCancellation()
          let peerMessages = peerCandidates.compactMap { candidate in
            messagesByKey[HomeTranslationMessageKey(
              chatID: candidate.chatID,
              messageID: candidate.messageID
            )]
          }
          let foundKeys = Set(peerMessages.map {
            HomeTranslationMessageKey(chatID: $0.chatId, messageID: $0.message.messageId)
          })
          let foundCandidates = peerCandidates.filter {
            foundKeys.contains(HomeTranslationMessageKey(
              chatID: $0.chatID,
              messageID: $0.messageID
            ))
          }
          missingCandidates.append(contentsOf: peerCandidates.filter {
            !foundCandidates.contains($0)
          })

          guard !peerMessages.isEmpty else { continue }
          let outcome = await TranslationViewModel.processMessagesForTranslation(
            for: peer,
            messages: peerMessages
          )
          switch outcome {
          case .completed:
            await core.finish(foundCandidates, outcome: .completed)
          case .retryableFailure:
            await core.finish(foundCandidates, outcome: .failed)
          case .cancelled:
            await core.finish(foundCandidates, outcome: .cancelled)
            throw CancellationError()
          }
        }

        await core.finish(missingCandidates, outcome: .failed)
      } catch is CancellationError {
        await core.finish(candidates, outcome: .cancelled)
      } catch {
        await core.finish(candidates, outcome: .failed)
      }

      let nextRetryDate = await core.nextRetryDate(eligiblePeers: eligibleRetryPeers)
      if candidates.count == batchLimit {
        // Drain the next bounded page even when every item in this page was
        // already in the target language and produced no database revision.
        return nextRetryDate.map { min($0, Date()) } ?? Date()
      }
      return nextRetryDate
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
    let delay = max(1, retryDate.timeIntervalSinceNow)
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
      enabledPeers: Set<Peer>,
      excluding currentPeers: Set<Peer>,
      generation: UInt64,
      limit: Int
    ) -> [HomeTranslationCandidate] {
      tracker.reserve(
        snapshots: snapshots,
        prioritizedPeers: [],
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

    func nextRetryDate(eligiblePeers: Set<Peer>) -> Date? {
      tracker.nextRetryDate(eligiblePeers: eligiblePeers)
    }
  }
}
