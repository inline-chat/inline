import Foundation
@testable import InlineKit
import Testing

@MainActor
private final class SendLog {
  var sends: [(peer: Peer, action: ApiComposeAction?)] = []
  var failNext = 0

  func record(_ peer: Peer, _ action: ApiComposeAction?) throws {
    sends.append((peer, action))
    if failNext > 0 {
      failNext -= 1
      throw URLError(.timedOut)
    }
  }

  var actions: [ApiComposeAction?] { sends.map(\.action) }
}

@MainActor
private func makeActions(
  _ log: SendLog,
  refresh: Duration = .milliseconds(30)
) -> ComposeActions {
  ComposeActions(refreshInterval: refresh) { peer, action in
    try log.record(peer, action)
  }
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

@MainActor
@Suite("Outgoing compose activities")
struct ComposeActionOutgoingTests {
  let peer = Peer.thread(id: 900)

  @Test("sends the action, refreshes it, then stops once")
  func singleUploadLifecycle() async {
    let log = SendLog()
    let actions = makeActions(log)

    let upload = actions.beginActivity(.uploadingPhoto, in: peer)
    #expect(await waitUntil { log.actions.count >= 3 })
    #expect(log.actions.allSatisfy { $0 == .uploadingPhoto })

    actions.endActivity(upload)
    #expect(await waitUntil { log.actions.last == .some(nil) })
    let countAfterStop = log.actions.count
    try? await Task.sleep(for: .milliseconds(120))
    #expect(log.actions.count == countAfterStop, "no refresh may follow the stop")
    #expect(log.actions.filter { $0 == nil }.count == 1)
    #expect(actions.outgoingAction(in: peer) == nil)
  }

  @Test("overlapping uploads keep the status until the last one ends")
  func overlappingUploadsShareOneStatus() async {
    let log = SendLog()
    let actions = makeActions(log)

    let first = actions.beginActivity(.uploadingPhoto, in: peer)
    let second = actions.beginActivity(.uploadingPhoto, in: peer)
    #expect(await waitUntil { !log.actions.isEmpty })

    actions.endActivity(first)
    let mark = log.actions.count
    #expect(await waitUntil { log.actions.count >= mark + 2 })
    #expect(log.actions.contains { $0 == nil } == false, "the first finishing must not clear the second")

    actions.endActivity(second)
    #expect(await waitUntil { log.actions.last == .some(nil) })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(log.actions.last == .some(nil))
    #expect(log.actions.filter { $0 == nil }.count == 1)
  }

  @Test("an activity that ends before its first send sends nothing")
  func instantActivitySendsNothing() async {
    let log = SendLog()
    let actions = makeActions(log)
    actions.endActivity(actions.beginActivity(.uploadingPhoto, in: peer))
    try? await Task.sleep(for: .milliseconds(80))
    #expect(log.actions.isEmpty)
  }

  @Test("ending twice is harmless")
  func endIsIdempotent() async {
    let log = SendLog()
    let actions = makeActions(log)
    let upload = actions.beginActivity(.uploadingDocument, in: peer)
    #expect(await waitUntil { !log.actions.isEmpty })
    actions.endActivity(upload)
    actions.endActivity(upload)
    #expect(await waitUntil { log.actions.last == .some(nil) })
    try? await Task.sleep(for: .milliseconds(80))
    #expect(log.actions.filter { $0 == nil }.count == 1)
  }

  @Test("a restart right after a stop sends the stop first")
  func restartIsOrderedAfterStop() async {
    let log = SendLog()
    let actions = makeActions(log)

    let first = actions.beginActivity(.uploadingPhoto, in: peer)
    #expect(await waitUntil { !log.actions.isEmpty })
    actions.endActivity(first)
    let second = actions.beginActivity(.uploadingVideo, in: peer)

    #expect(await waitUntil { log.actions.contains(.uploadingVideo) })
    let stopIndex = log.actions.firstIndex { $0 == nil }
    let videoIndex = log.actions.firstIndex { $0 == .uploadingVideo }
    #expect(stopIndex != nil)
    if let stopIndex, let videoIndex { #expect(stopIndex < videoIndex) }
    #expect(log.actions.filter { $0 == nil }.count == 1, "the old loop must not stop the new upload")
    #expect(log.actions.prefix(while: { $0 != nil }).allSatisfy { $0 == .uploadingPhoto })

    actions.endActivity(second)
    #expect(await waitUntil { log.actions.last == .some(nil) })
  }

  @Test("a failed send doesn't stop the refresh")
  func refreshSurvivesSendErrors() async {
    let log = SendLog()
    log.failNext = 2
    let actions = makeActions(log)

    let upload = actions.beginActivity(.uploadingVideo, in: peer)
    #expect(await waitUntil { log.actions.count >= 4 })
    actions.endActivity(upload)
    #expect(await waitUntil { log.actions.last == .some(nil) })
  }

  @Test("a long upload keeps its status; there is no wall-clock cutoff")
  func longUploadKeepsStatus() async {
    let log = SendLog()
    let actions = makeActions(log, refresh: .milliseconds(10))
    let upload = actions.beginActivity(.uploadingVideo, in: peer)
    #expect(await waitUntil { log.actions.count >= 15 })
    #expect(log.actions.allSatisfy { $0 == .uploadingVideo })
    actions.endActivity(upload)
    #expect(await waitUntil { log.actions.last == .some(nil) })
  }

  @Test("an incoming message clears its author's status, but not agent work")
  func messageArrivalClearsStatus() {
    let actions = makeActions(SendLog(), refresh: .seconds(10))
    let state = actions.activityState(for: peer)
    actions.addComposeAction(for: peer, action: .uploadingPhoto, userId: 5)
    actions.addComposeAction(for: peer, action: .working, userId: 6)

    actions.noteMessageArrived(in: peer, fromUserId: 5)
    #expect(actions.getComposeActions(for: peer)[5] == nil)
    #expect(actions.getComposeActions(for: peer)[6]?.action == .working)

    actions.noteMessageArrived(in: peer, fromUserId: 6)
    #expect(state.presentation?.action == .working)
    actions.noteMessageArrived(in: peer, fromUserId: 99)
    #expect(actions.getComposeActions(for: peer).count == 1)
  }

  @Test("received actions never touch our own status")
  func receivedActionsAreIsolated() async {
    let log = SendLog()
    let actions = makeActions(log)

    let upload = actions.beginActivity(.uploadingPhoto, in: peer)
    actions.addComposeAction(for: peer, action: .typing, userId: 42)
    actions.removeAllComposeActions(for: peer)
    actions.removeComposeAction(for: peer, userId: 42)

    let mark = log.actions.count
    #expect(await waitUntil { log.actions.count >= mark + 2 })
    #expect(log.actions.contains { $0 == nil } == false)
    actions.endActivity(upload)
    #expect(await waitUntil { log.actions.last == .some(nil) })
  }

  @Test("typing stays quiet while sending media")
  func typingIsSuppressedDuringUpload() async {
    let log = SendLog()
    let actions = makeActions(log, refresh: .seconds(10))

    let upload = actions.beginActivity(.uploadingPhoto, in: peer)
    #expect(await waitUntil { log.actions == [.uploadingPhoto] })
    await actions.startedTyping(for: peer)
    await actions.stoppedTyping(for: peer)
    #expect(log.actions == [.uploadingPhoto])
    actions.endActivity(upload)
    #expect(await waitUntil { log.actions == [.uploadingPhoto, nil] })
  }

  @Test("the strongest activity in a chat wins")
  func priority() {
    let actions = makeActions(SendLog(), refresh: .seconds(10))
    let document = actions.beginActivity(.uploadingDocument, in: peer)
    #expect(actions.outgoingAction(in: peer) == .uploadingDocument)
    let photo = actions.beginActivity(.uploadingPhoto, in: peer)
    #expect(actions.outgoingAction(in: peer) == .uploadingPhoto)
    let video = actions.beginActivity(.uploadingVideo, in: peer)
    #expect(actions.outgoingAction(in: peer) == .uploadingVideo)
    actions.endActivity(video)
    #expect(actions.outgoingAction(in: peer) == .uploadingPhoto)
    actions.endActivity(photo)
    actions.endActivity(document)
    #expect(actions.outgoingAction(in: peer) == nil)
  }

  @Test("chats are independent")
  func chatsAreIndependent() async {
    let log = SendLog()
    let actions = makeActions(log)
    let other = Peer.user(id: 77)

    let a = actions.beginActivity(.uploadingPhoto, in: peer)
    let b = actions.beginActivity(.uploadingDocument, in: other)
    #expect(await waitUntil { log.sends.count >= 2 })
    actions.endActivity(a)
    #expect(await waitUntil { log.sends.contains { $0.peer == peer && $0.action == nil } })
    #expect(actions.outgoingAction(in: other) == .uploadingDocument)
    actions.endActivity(b)
    #expect(await waitUntil { log.sends.contains { $0.peer == other && $0.action == nil } })
  }

  @Test("the human copy reads like sending")
  func copy() {
    #expect(ApiComposeAction.uploadingPhoto.toHumanReadableForIOS() == "sending photo")
    #expect(ApiComposeAction.uploadingVideo.toHumanReadableForIOS() == "sending video")
    #expect(ApiComposeAction.uploadingDocument.toHumanReadableForIOS() == "sending file")
  }
}
