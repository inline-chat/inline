import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Grid transcription control")
struct GridTranscriptionControlTests {
  private func room(state: Int? = nil) -> GridRoom {
    .with {
      $0.id = 7
      $0.spaceID = 42
      $0.transcriptionAvailable = true
      $0.connection = .with { $0.generation = 3 }
      $0.avatars = [.with { $0.ownedByCurrentSession = true
        $0.membershipID = "member-1"
      }]
      if let state {
        $0.transcription = .with {
          $0.runID = "run-1"
          $0.revision = 8
          $0.state = GridTranscriptionState(rawValue: state)!
          $0.transcriptChatID = 999
        }
      }
    }
  }

  @Test("the action captures membership, generation, run and revision in one snapshot")
  func fencedSnapshotSurvivesRetryEncoding() throws {
    let request = try #require(GridTranscriptionRequest(room: room(state: 2), enabled: false, requestID: "intent-1"))
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(GridTranscriptionRequest.self, from: encoded)
    let input = decoded.input
    #expect(decoded == request)
    #expect(input.roomID == 7)
    #expect(input.expectedMembershipID == "member-1")
    #expect(input.expectedGeneration == 3)
    #expect(input.expectedRunID == "run-1")
    #expect(input.expectedRevision == 8)
    #expect(input.requestID == "intent-1")
    #expect(!input.enabled)
    #expect(SetGridTranscriptionTransaction(request: request).effectiveReconnectReplayPolicy == .neverReplay)
  }

  @Test("new destination and existing destination stay explicit without model UI fields")
  func explicitDestination() throws {
    let fresh = try #require(GridTranscriptionRequest(room: room(), enabled: true, destination: .new))
    #expect(fresh.input.destination.rawValue == 1)
    #expect(!fresh.input.hasExpectedRunID)
    #expect(!fresh.input.hasTranscriptChatID)
    let continued = try #require(GridTranscriptionRequest(room: room(), enabled: true, destination: .existing(99)))
    #expect(continued.input.destination.rawValue == 2)
    #expect(continued.input.transcriptChatID == 99)
    #expect(GridTranscriptionRequest(room: room(), enabled: true, destination: .existing(0)) == nil)
  }

  @Test("unavailable, unowned, pending and future states cannot advertise an action")
  func noInertOrUnfencedControl() {
    var unavailable = room()
    unavailable.transcriptionAvailable = false
    #expect(GridTranscriptionRequest(room: unavailable, enabled: true) == nil)
    var observer = room()
    observer.avatars[0].ownedByCurrentSession = false
    #expect(GridTranscriptionRequest(room: observer, enabled: true) == nil)
    var noGeneration = room()
    noGeneration.clearConnection()
    #expect(GridTranscriptionRequest(room: noGeneration, enabled: true) == nil)
    #expect(GridTranscriptionRequest(room: room(state: 1), enabled: true) == nil)
    #expect(GridTranscriptionRequest(room: room(state: 1), enabled: false) != nil)
    #expect(GridTranscriptionRequest(room: room(state: 3), enabled: false) == nil)
    #expect(GridTranscriptionRequest(room: room(state: 99), enabled: true) == nil)
    #expect(room(state: 1).transcriptionControlTitle == "Cancel transcription")
    #expect(room(state: 3).transcriptionControlTitle == "Stopping…")
    #expect(room(state: 5).transcriptionControlTitle == "Start transcription")
  }

  @Test("worker availability cannot strand an existing capture without stop")
  func stopRemainsAvailableWhenWorkerDrops() {
    var active = room(state: 2)
    active.transcriptionAvailable = false
    #expect(GridTranscriptionRequest(room: active, enabled: false) != nil)
    #expect(GridTranscriptionRequest(room: active, enabled: true) == nil)
    var starting = room(state: 1)
    starting.transcriptionAvailable = false
    #expect(GridTranscriptionRequest(room: starting, enabled: false) != nil)
  }
}
