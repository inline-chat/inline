import Foundation

public struct HomeTranslationCandidate: Equatable, Hashable, Sendable {
  public let peer: Peer
  public let chatID: Int64
  public let messageID: Int64
  public let signature: ChatListContentSignature
  public let generation: UInt64
  public let attempt: Int

  public init(
    peer: Peer,
    chatID: Int64,
    messageID: Int64,
    signature: ChatListContentSignature,
    generation: UInt64,
    attempt: Int
  ) {
    self.peer = peer
    self.chatID = chatID
    self.messageID = messageID
    self.signature = signature
    self.generation = generation
    self.attempt = attempt
  }
}

public enum HomeTranslationWorkOutcome: Sendable {
  case completed
  case failed
  case cancelled
}

/// Pure retry and reservation policy for Home's translated last-message previews.
/// A dispatch is not success: processing completes only after persistence is
/// verified or the message is determined not to need translation.
public struct HomeTranslationWorkTracker: Sendable {
  private enum WorkState: Sendable {
    case inFlight(
      signature: ChatListContentSignature,
      attempt: Int,
      generation: UInt64
    )
    case retryAfter(signature: ChatListContentSignature, attempt: Int, date: Date)
    case completed(signature: ChatListContentSignature)

    var signature: ChatListContentSignature {
      switch self {
      case let .inFlight(signature, _, _),
           let .retryAfter(signature, _, _),
           let .completed(signature):
        signature
      }
    }
  }

  private let baseRetryDelay: TimeInterval
  private let maximumRetryDelay: TimeInterval
  private var states: [Peer: WorkState] = [:]

  public init(
    baseRetryDelay: TimeInterval = 2,
    maximumRetryDelay: TimeInterval = 30
  ) {
    self.baseRetryDelay = baseRetryDelay
    self.maximumRetryDelay = maximumRetryDelay
  }

  public mutating func beginGeneration(_ generation: UInt64) {
    let stalePeers = states.compactMap { peer, state -> Peer? in
      guard case let .inFlight(_, _, reservedGeneration) = state,
            reservedGeneration < generation
      else { return nil }
      return peer
    }

    // Cancellation is not a failure. The replacement pass may immediately
    // reclaim the same signature, while late completion from the old pass is
    // rejected by its generation.
    for peer in stalePeers {
      states.removeValue(forKey: peer)
    }
  }

  public mutating func reserve(
    snapshots: [ChatListItemSnapshot],
    prioritizedPeers: [Peer],
    enabledPeers: Set<Peer>,
    excluding excludedPeers: Set<Peer>,
    generation: UInt64,
    limit: Int,
    now: Date = Date()
  ) -> [HomeTranslationCandidate] {
    guard limit > 0 else { return [] }

    var snapshotsByPeer: [Peer: ChatListItemSnapshot] = [:]
    var snapshotOrder: [Peer] = []
    for snapshot in snapshots where snapshotsByPeer[snapshot.peer] == nil {
      snapshotsByPeer[snapshot.peer] = snapshot
      snapshotOrder.append(snapshot.peer)
    }

    let livePeers = Set(snapshotsByPeer.keys)
    states = states.filter { livePeers.contains($0.key) && enabledPeers.contains($0.key) }

    for snapshot in snapshotsByPeer.values {
      if states[snapshot.peer]?.signature != snapshot.contentSignature {
        states.removeValue(forKey: snapshot.peer)
      }

      if snapshot.translatedPreviewText != nil {
        states[snapshot.peer] = .completed(signature: snapshot.contentSignature)
      }
    }

    var orderedPeers: [Peer] = []
    var seenPeers = Set<Peer>()
    for peer in prioritizedPeers + snapshotOrder where seenPeers.insert(peer).inserted {
      orderedPeers.append(peer)
    }

    var candidates: [HomeTranslationCandidate] = []
    candidates.reserveCapacity(min(limit, orderedPeers.count))

    for peer in orderedPeers {
      guard candidates.count < limit,
            enabledPeers.contains(peer),
            !excludedPeers.contains(peer),
            let snapshot = snapshotsByPeer[peer],
            snapshot.contentSignature.draftRevision == nil,
            let messageID = snapshot.contentSignature.messageID
      else { continue }

      let nextAttempt: Int
      switch states[peer] {
      case .completed, .inFlight:
        continue
      case let .retryAfter(_, attempt, date):
        guard date <= now else { continue }
        nextAttempt = attempt == .max ? .max : attempt + 1
      case nil:
        nextAttempt = 1
      }

      let candidate = HomeTranslationCandidate(
        peer: peer,
        chatID: snapshot.chatID,
        messageID: messageID,
        signature: snapshot.contentSignature,
        generation: generation,
        attempt: nextAttempt
      )
      states[peer] = .inFlight(
        signature: snapshot.contentSignature,
        attempt: nextAttempt,
        generation: generation
      )
      candidates.append(candidate)
    }

    return candidates
  }

  public mutating func finish(
    _ candidates: [HomeTranslationCandidate],
    outcome: HomeTranslationWorkOutcome,
    now: Date = Date()
  ) {
    for candidate in candidates {
      guard case let .inFlight(signature, attempt, generation) = states[candidate.peer],
            signature == candidate.signature,
            generation == candidate.generation
      else { continue }

      switch outcome {
      case .cancelled:
        states.removeValue(forKey: candidate.peer)
      case .completed:
        states[candidate.peer] = .completed(signature: candidate.signature)
      case .failed:
        let exponent = min(max(0, attempt - 1), 16)
        let delay = min(baseRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
        states[candidate.peer] = .retryAfter(
          signature: candidate.signature,
          attempt: attempt,
          date: now.addingTimeInterval(delay)
        )
      }
    }
  }

  public mutating func reset(peer: Peer) {
    states.removeValue(forKey: peer)
  }

  public func nextRetryDate(eligiblePeers: Set<Peer>? = nil) -> Date? {
    states.compactMap { peer, state in
      guard eligiblePeers?.contains(peer) ?? true else { return nil }
      guard case let .retryAfter(_, _, date) = state else { return nil }
      return date
    }.min()
  }
}
