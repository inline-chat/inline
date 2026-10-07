import Foundation
import InlineProtocol

/// A single server snapshot fences a room action. A retry keeps this request ID
/// and never turns a stale stop into a stop for a replacement run.
public struct GridTranscriptionRequest: Codable, Sendable, Equatable {
  public enum Destination: Codable, Sendable, Equatable {
    case last
    case new
    case existing(Int64)
  }

  public let roomID: Int64
  public let membershipID: String
  public let generation: Int32
  public let runID: String?
  public let revision: Int32
  public let enabled: Bool
  public let destination: Destination
  public let requestID: String

  public init?(room: GridRoom, enabled: Bool, destination: Destination = .last, requestID: String = UUID().uuidString) {
    guard room.hasConnection,
          let avatar = room.avatars.first(where: \.ownedByCurrentSession),
          !avatar.membershipID.isEmpty,
          room.connection.generation > 0,
          enabled ? room.canStartTranscription : room.canStopTranscription
    else { return nil }
    if case let .existing(chatID) = destination, chatID <= 0 {
      return nil
    }

    roomID = room.id
    membershipID = avatar.membershipID
    generation = room.connection.generation
    runID = room.hasTranscription && !room.transcription.runID.isEmpty ? room.transcription.runID : nil
    revision = room.hasTranscription ? room.transcription.revision : 0
    self.enabled = enabled
    self.destination = destination
    self.requestID = requestID
  }

  public var input: SetGridTranscriptionInput {
    .with {
      $0.roomID = roomID
      $0.expectedMembershipID = membershipID
      $0.expectedGeneration = generation
      if let runID {
        $0.expectedRunID = runID
      }
      $0.expectedRevision = revision
      $0.enabled = enabled
      switch destination {
        case .last: $0.destination = .gridTranscriptLast
        case .new: $0.destination = .gridTranscriptNew
        case let .existing(chatID):
          $0.destination = .gridTranscriptExisting
          $0.transcriptChatID = chatID
      }
      $0.requestID = requestID
    }
  }
}

public extension GridRoom {
  var transcriptChatID: Int64? {
    guard hasTranscription, transcription.hasTranscriptChatID, transcription.transcriptChatID > 0 else { return nil }
    return transcription.transcriptChatID
  }

  var transcriptionIsRunning: Bool {
    hasTranscription && [.gridTranscriptionStarting, .gridTranscriptionActive, .gridTranscriptionStopping]
      .contains(transcription.state)
  }

  var transcriptionCanChange: Bool {
    canStartTranscription || canStopTranscription
  }

  var canStartTranscription: Bool {
    guard transcriptionAvailable else { return false }
    guard hasTranscription else { return true }
    // Unknown future states are read-only until a client understands them.
    return [.gridTranscriptionStopped, .gridTranscriptionInterrupted].contains(transcription.state)
  }

  var canStopTranscription: Bool {
    hasTranscription && [.gridTranscriptionStarting, .gridTranscriptionActive].contains(transcription.state)
  }

  var transcriptionControlTitle: String {
    guard hasTranscription else { return "Start transcription" }
    switch transcription.state {
      case .gridTranscriptionStarting: return "Cancel transcription"
      case .gridTranscriptionActive: return "Stop transcription"
      case .gridTranscriptionStopping: return "Stopping…"
      case .gridTranscriptionStopped, .gridTranscriptionInterrupted: return "Start transcription"
      default: return "Transcription unavailable"
    }
  }
}
