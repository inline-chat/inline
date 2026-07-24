public struct GridScreenShareAloneGraceState: Equatable, Sendable {
  public static let graceDuration: Duration = .seconds(5)

  public enum Action: Equatable, Sendable {
    case reset
    case cancelPendingStop
    case scheduleStop(publicationIDs: Set<String>)
  }

  public struct Context: Equatable, Sendable {
    public let episodeID: UInt64
    public let isConnected: Bool
    public let isShareRequested: Bool
    public let localPublicationIDs: Set<String>
    public let hasRemoteParticipant: Bool

    public init(
      episodeID: UInt64,
      isConnected: Bool,
      isShareRequested: Bool,
      localPublicationIDs: Set<String>,
      hasRemoteParticipant: Bool
    ) {
      self.episodeID = episodeID
      self.isConnected = isConnected
      self.isShareRequested = isShareRequested
      self.localPublicationIDs = localPublicationIDs
      self.hasRemoteParticipant = hasRemoteParticipant
    }
  }

  public private(set) var episodeID: UInt64?
  public private(set) var publicationIDs = Set<String>()
  public private(set) var hasHadRemoteParticipant = false

  public init() {}

  public mutating func reset() {
    episodeID = nil
    publicationIDs = []
    hasHadRemoteParticipant = false
  }

  public mutating func reconcile(_ context: Context) -> Action {
    guard context.isShareRequested else {
      reset()
      return .reset
    }

    if episodeID != context.episodeID {
      reset()
      episodeID = context.episodeID
    }

    // A requested sharing episode owns its peer history across provider-room
    // reconstruction and publication gaps. Only explicit Stop or a new episode
    // may clear it.
    guard context.isConnected, !context.localPublicationIDs.isEmpty else {
      return .cancelPendingStop
    }

    if publicationIDs != context.localPublicationIDs {
      let continuesExistingShare = !publicationIDs.isEmpty
      publicationIDs = context.localPublicationIDs
      if continuesExistingShare {
        hasHadRemoteParticipant =
          hasHadRemoteParticipant || context.hasRemoteParticipant
      } else {
        hasHadRemoteParticipant = context.hasRemoteParticipant
      }
    }

    if context.hasRemoteParticipant {
      hasHadRemoteParticipant = true
      return .cancelPendingStop
    }

    guard hasHadRemoteParticipant else { return .cancelPendingStop }
    return .scheduleStop(publicationIDs: context.localPublicationIDs)
  }

  public static func shouldCommitScheduledStop(
    _ context: Context,
    expectedEpisodeID: UInt64,
    expectedPublicationIDs: Set<String>
  ) -> Bool {
    context.isConnected
      && context.isShareRequested
      && context.episodeID == expectedEpisodeID
      && !context.localPublicationIDs.isEmpty
      && context.localPublicationIDs == expectedPublicationIDs
      && !context.hasRemoteParticipant
  }
}
