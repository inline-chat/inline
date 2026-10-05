import Combine
import Foundation
@testable import InlineAudioPlayback
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit

/// Exercises the production adapter, account fence and native transition queue. Transfer
/// delivery, engine responses and native completion are controlled at their boundaries.
@MainActor
@Suite("Voice playback requests", .serialized)
struct VoicePlaybackRequestTests {
  @Test("a late A completion cannot replace or pause the selected B")
  func outOfOrderCompletions() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let a = voiceMessage(1), b = voiceMessage(2)
    fixture.player.requestVoicePlayback(for: a)
    fixture.downloads.progress(voiceID: 101, received: 25, total: 100)
    #expect(fixture.player.loadingVoice?.progress == 0.25)

    fixture.player.requestVoicePlayback(for: b)
    #expect(fixture.downloads.cancelled == [101])
    fixture.downloads.complete(0, with: .success(requestURL("a")))
    #expect(fixture.engine.loadCount == 0)
    #expect(fixture.player.loadingVoice?.item.messageId == 2)
    fixture.downloads.progress(voiceID: 101, received: 100, total: 100)
    #expect(fixture.player.loadingVoice?.progress == nil)
    fixture.downloads.progress(voiceID: 102, received: 50, total: 100)
    #expect(fixture.player.loadingVoice?.progress == 0.5)

    fixture.downloads.complete(1, with: .success(requestURL("b")))
    #expect(fixture.player.state.item?.messageId == 2)
    #expect(fixture.player.state.sourceURL == requestURL("b"))
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.player.state.display?.senderName == "Sender 2")
    #expect(fixture.player.loadingVoice == nil)
    fixture.downloads.complete(0, with: .failure(URLError(.cannotDecodeContentData)))
    #expect(fixture.player.playbackError == nil)
    #expect(fixture.engine.loadCount == 1)
    #expect(fixture.engine.playCount == 1)
    fixture.downloads.complete(0, with: .success(requestURL("late-a")))
    #expect(fixture.player.state.sourceURL == requestURL("b"))
    #expect(fixture.engine.loadCount == 1)
  }

  @Test("a same-message retry admits only its latest completion")
  func sameMessageRetry() {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    fixture.player.requestVoicePlayback(for: message)
    fixture.player.cancelVoiceSelection(mediaID: 101)
    fixture.player.requestVoicePlayback(for: message)
    fixture.downloads.complete(0, with: .success(requestURL("old")))
    #expect(fixture.engine.loadCount == 0)
    #expect(fixture.player.loadingVoice != nil)
    fixture.downloads.complete(1, with: .success(requestURL("retry")))
    fixture.downloads.complete(0, with: .success(requestURL("old")))
    #expect(fixture.player.state.sourceURL == requestURL("retry"))
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.engine.loadCount == 1)
    #expect(fixture.engine.playCount == 1)
  }

  @Test("retry subscribes to the replacement subject after retained terminal progress",
        arguments: ["completed", "failed"])
  func terminalProgressRetry(terminal: String) {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    fixture.player.requestVoicePlayback(for: message)
    if terminal == "completed" {
      fixture.downloads.finishProgress(voiceID: 101,
        progress: DownloadProgress(id: "voice_101", bytesReceived: 100, totalBytes: 100))
      fixture.engine.failureStage = "load"
      fixture.downloads.complete(0, with: .success(requestURL("downloaded-but-unreadable")))
    } else {
      fixture.downloads.finishProgress(voiceID: 101,
        progress: DownloadProgress(id: "voice_101", bytesReceived: 0, totalBytes: 0,
                                   error: URLError(.cannotConnectToHost)))
      fixture.downloads.complete(0, with: .failure(URLError(.cannotConnectToHost)))
    }
    fixture.engine.failureStage = nil
    fixture.downloads.initialProgress = DownloadProgress(id: "voice_101", bytesReceived: 25, totalBytes: 100)
    fixture.player.requestVoicePlayback(for: message)
    // The replacement subject retains progress emitted synchronously during start.
    #expect(fixture.player.loadingVoice?.progress == 0.25)
    fixture.downloads.progress(voiceID: 101, received: 50, total: 100)
    #expect(fixture.player.loadingVoice?.progress == 0.5)
    fixture.downloads.complete(1, with: .success(requestURL("terminal-retry")))
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.player.loadingVoice == nil)
  }

  @Test("synchronous transfer completion leaves no progress subscription",
        arguments: ["success", "failure"])
  func synchronousTransferCompletion(result: String) {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.downloads.synchronousResult = result == "success"
      ? .success(requestURL("synchronous")) : .failure(URLError(.cannotConnectToHost))
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    #expect(fixture.player.loadingVoice == nil)
    #expect(fixture.downloads.publisherRequests.isEmpty)
    #expect(fixture.player.state.isPlaying == (result == "success"))
    #expect((fixture.player.playbackError != nil) == (result == "failure"))
  }

  @Test("a local toggle immediately follows authoritative remote pause", arguments: ["bubble", "current"])
  func immediateToggleAfterRemotePause(action: String) throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: message, fileURLOverride: url)
    let identity = try #require(fixture.center.remoteCommandIdentity)
    #expect(fixture.center.handleRemoteCommand(.pause, expectedIdentity: identity))
    #expect(!fixture.center.isPlaying)
    #expect(fixture.player.state.isPlaying) // Its observer is deliberately not given an actor yield.
    if action == "bubble" { try fixture.player.toggleVoicePlayback(for: message, fileURLOverride: url) }
    else { fixture.player.toggleCurrentPlayback() }
    #expect(fixture.center.isPlaying)
    #expect(fixture.engine.isPlaying)
    #expect(fixture.engine.playCount == 2)
  }

  @Test("natural completion permits immediate same-item selection before projection catches up",
        arguments: ["request", "toggle", "prepare"])
  func immediateSelectionAfterNaturalCompletion(action: String) throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: message, fileURLOverride: url)
    let target = try #require(fixture.player.state.openTarget)
    fixture.engine.finishNaturally()
    #expect(fixture.center.item == nil)
    #expect(fixture.player.state.item?.mediaId == 101)
    #expect(fixture.player.voiceNavigationAccount(for: target) == nil)
    switch action {
    case "request": fixture.player.requestVoicePlayback(for: message, fileURLOverride: url)
    case "toggle": try fixture.player.toggleVoicePlayback(for: message, fileURLOverride: url)
    default: try fixture.player.prepareVoice(for: message, fileURLOverride: url)
    }
    #expect(fixture.center.item?.mediaId == 101)
    #expect(fixture.engine.loadCount == 2)
    #expect(fixture.center.isPlaying == (action != "prepare"))
    #expect(fixture.engine.playCount == (action == "prepare" ? 1 : 2))
  }

  @Test("the bubble seek path re-prepares immediately after natural completion")
  func bubbleSeekAfterNaturalCompletion() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: message, fileURLOverride: url)
    fixture.engine.finishNaturally()
    #expect(fixture.player.state.item?.mediaId == 101)
    #expect(fixture.center.item == nil)
    // VoiceMessageBubble.handleSeek uses this exact caller sequence. No actor yield
    // permits the facade's delayed projection to repair the selection decision.
    if !fixture.player.isCurrentVoice(message) {
      try fixture.player.prepareVoice(for: message, fileURLOverride: url)
    }
    fixture.player.seekVoice(to: 0.5, for: message)
    #expect(fixture.center.item?.mediaId == 101)
    #expect(fixture.engine.loadCount == 2)
    #expect(fixture.engine.currentTime == 6)
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.engine.playCount == 1)
  }

  @Test("an old projected voice cannot seek the center's newer item")
  func staleVoiceCannotSeekCurrentItem() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let a = voiceMessage(1), b = voiceMessage(2)
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: a, fileURLOverride: url)
    try fixture.center.play(fileURL: url,
      item: AudioPlaybackItem(kind: .voice, chatId: b.chatId, messageId: b.messageId, mediaId: 102),
      presentation: AudioPlaybackPresentation(display: AudioPlaybackDisplay(title: "B")))
    fixture.center.seek(toTime: 3)
    #expect(fixture.player.state.item?.mediaId == 101)
    #expect(fixture.center.item?.mediaId == 102)
    #expect(!fixture.player.isCurrentVoice(a))
    #expect(fixture.player.isCurrentVoice(b))
    fixture.player.seekVoice(to: 0.5, for: a)
    #expect(fixture.engine.currentTime == 3)
    #expect(fixture.center.item?.mediaId == 102)
    #expect(fixture.engine.isPlaying)
  }

  @Test("nested local data maintenance denies selection and resume until its outer release")
  func nestedLocalDataMaintenance() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: message, fileURLOverride: url)
    let identity = try #require(fixture.center.remoteCommandIdentity)
    let target = try #require(fixture.player.state.openTarget)
    fixture.player.beginLocalDataMaintenance()
    fixture.player.beginLocalDataMaintenance()
    #expect(fixture.center.item == nil)
    #expect(!fixture.center.canResume())
    #expect(fixture.player.voiceNavigationAccount(for: target) == nil)
    #expect(!fixture.center.handleRemoteCommand(.play, expectedIdentity: identity))
    #expect(throws: AudioPlaybackError.self) { try fixture.player.resumeCurrentPlayback() }
    #expect(throws: AudioPlaybackError.self) {
      try fixture.player.toggleVoicePlayback(for: message, fileURLOverride: url)
    }
    fixture.player.requestVoicePlayback(for: message)
    #expect(fixture.downloads.completions.isEmpty)
    fixture.player.endLocalDataMaintenance()
    #expect(throws: AudioPlaybackError.self) { try fixture.player.prepareVoice(for: message, fileURLOverride: url) }
    fixture.player.requestVoicePlayback(for: message)
    #expect(fixture.downloads.completions.isEmpty)
    fixture.player.endLocalDataMaintenance()
    fixture.player.requestVoicePlayback(for: message)
    #expect(fixture.downloads.completions.count == 1)
    fixture.downloads.complete(0, with: .success(requestURL("after-maintenance")))
    #expect(fixture.center.isPlaying)
    #expect(fixture.center.canResume())
    #expect(fixture.engine.loadCount == 2)
  }

  @Test("voice navigation retains selection authority and rejects a fresh same-user generation",
        arguments: [false, true])
  func retainedNavigationAuthority(loaded: Bool) throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    if loaded { fixture.downloads.complete(0, with: .success(requestURL("navigation"))) }
    let target = AudioPlaybackOpenTarget(peer: .thread(id: 44), chatId: 44, messageId: 1)
    let selectedAccount = try fixture.auth.beginAccountMutation()
    #expect(fixture.player.voiceNavigationAccount(for: target) == selectedAccount)
    let wrongTarget = AudioPlaybackOpenTarget(peer: .thread(id: 44), chatId: 44, messageId: 2)
    #expect(fixture.player.voiceNavigationAccount(for: wrongTarget) == nil)
    _ = try fixture.replaceAccountSynchronously(userID: 7)
    // No suspension: navigation must not mint a new token for the old pill.
    #expect(fixture.player.voiceNavigationAccount(for: target) == nil)
  }

  @Test("cancelling a suspended native activation never prepares or starts canceled voice",
        arguments: ["pause", "close", "seek", "toggle", "reset", "logout", "account", "maintenance"])
  func cancelledNativeActivation(action: String) async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    try fixture.player.prepareVoice(for: voiceMessage(1), fileURLOverride: voicePCMFixture())
    var completion: Result<Void, Error>?
    try fixture.center.resume { completion = $0 }
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    #expect(fixture.center.isStarting)
    #expect(fixture.engine.prepareCount == 0)
    #expect(fixture.engine.playCount == 0)
    switch action {
    case "pause": fixture.player.pause()
    case "close": fixture.player.stop()
    case "seek": fixture.player.seekCurrent(to: 0.5)
    case "toggle": fixture.player.toggleCurrentPlayback()
    case "reset": fixture.center.mediaServicesWereReset()
    case "logout": _ = try fixture.store.beginLogoutSynchronously()
    case "account": _ = try fixture.replaceAccountSynchronously(userID: 7)
    default: fixture.player.beginLocalDataMaintenance()
    }
    try await backend.finishActivation()
    try await waitForVoiceCondition { completion != nil }
    try await waitForSessionCondition { await backend.pendingReleases == 1 }
    try await backend.finishRelease()
    if action == "reset" { try await waitForSessionCondition { await backend.didInvalidate } }
    if case let .failure(error)? = completion { #expect(error is CancellationError) }
    else { Issue.record("Canceled native activation did not complete as cancellation.") }
    #expect(fixture.engine.prepareCount == 0)
    #expect(fixture.engine.playCount == 0)
    #expect(!fixture.center.isPlaying)
    #expect(!fixture.center.isStarting)
    #expect(session.current == nil)
    #expect(fixture.player.playbackError == nil)
    if action == "maintenance" { fixture.player.endLocalDataMaintenance() }
  }

  @Test("replacement waits for old native release and stale activation cannot affect B",
        arguments: [false, true])
  func replacementDuringNativeActivation(oldActivationFails: Bool) async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("native-a")))
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    let oldToken = try #require(session.current)
    fixture.player.requestVoicePlayback(for: voiceMessage(2))
    fixture.downloads.complete(1, with: .success(requestURL("native-b")))
    let replacementToken = try #require(session.current)
    #expect(oldToken != replacementToken)
    #expect(fixture.center.item?.mediaId == 102)
    #expect(fixture.engine.playCount == 0)
    try await backend.finishActivation(failing: oldActivationFails)
    try await waitForSessionCondition { await backend.pendingReleases == 1 }
    let beforeRelease = await backend.operations
    #expect(beforeRelease == [.activate(oldToken), .release(oldToken)])
    #expect(fixture.engine.prepareCount == 0)
    #expect(fixture.engine.playCount == 0)
    try await backend.finishRelease()
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    let beforeBStarts = await backend.operations
    #expect(beforeBStarts == [.activate(oldToken), .release(oldToken), .activate(replacementToken)])
    try await backend.finishActivation()
    try await waitForVoiceCondition { fixture.player.state.isPlaying }
    #expect(fixture.player.state.item?.mediaId == 102)
    #expect(fixture.engine.prepareCount == 1)
    #expect(fixture.engine.playCount == 1)
    #expect(session.owns(replacementToken))
    #expect(fixture.player.playbackError == nil)
  }

  @Test("repeated resume gives its successor a fresh lease and old cleanup cannot revoke it")
  func repeatedNativeResume() async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    try fixture.player.prepareVoice(for: voiceMessage(1), fileURLOverride: voicePCMFixture())
    var firstResult: Result<Void, Error>?, secondResult: Result<Void, Error>?
    try fixture.center.resume { firstResult = $0 }
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    let firstToken = try #require(session.current)
    try fixture.center.resume { secondResult = $0 }
    let secondToken = try #require(session.current)
    #expect(firstToken != secondToken)
    try await backend.finishActivation()
    try await waitForVoiceCondition { firstResult != nil }
    try await waitForSessionCondition { await backend.pendingReleases == 1 }
    try await backend.finishRelease()
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    try await backend.finishActivation()
    try await waitForVoiceCondition { secondResult != nil }
    if case .success? = secondResult {} else { Issue.record("The latest native resume did not start.") }
    #expect(fixture.engine.playCount == 1)
    #expect(fixture.center.isPlaying)
    #expect(session.owns(secondToken))
    let staleRelease = session.release(firstToken)
    #expect(staleRelease == nil)
    #expect(session.owns(secondToken))
  }

  @Test("a failed native release finishes before successor activation and only successor outcome is reported",
        arguments: [false, true])
  func nativeReleaseFailureOrdering(successorFails: Bool) async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    let url = try voicePCMFixture()
    try fixture.player.playVoice(for: voiceMessage(1), fileURLOverride: url)
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    let oldToken = try #require(session.current)
    try await backend.finishActivation()
    try await waitForVoiceCondition { fixture.center.isPlaying }
    fixture.player.pause()
    try await waitForSessionCondition { await backend.pendingReleases == 1 }
    try fixture.player.playVoice(for: voiceMessage(2), fileURLOverride: url)
    let nextToken = try #require(session.current)
    let whileReleaseWaits = await backend.operations
    #expect(whileReleaseWaits == [.activate(oldToken), .release(oldToken)])
    #expect(fixture.engine.playCount == 1)
    try await backend.finishRelease(failing: true)
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    let afterFailedRelease = await backend.operations
    #expect(afterFailedRelease == [.activate(oldToken), .release(oldToken), .activate(nextToken)])
    #expect(fixture.engine.playCount == 1)
    // A successful platform activation represents recovery of the old teardown;
    // failing that recovery must leave B loaded, unplayed and retryable.
    try await backend.finishActivation(failing: successorFails)
    try await waitForVoiceCondition { !fixture.center.isStarting }
    #expect(fixture.center.item?.mediaId == 102)
    #expect(fixture.center.isPlaying == !successorFails)
    #expect(fixture.engine.playCount == (successorFails ? 1 : 2))
    try await waitForVoiceCondition { (fixture.player.playbackError != nil) == successorFails }
    #expect((session.current != nil) == !successorFails)
  }

  @Test("speed changes during native activation preserve the admitted start and apply the latest rate")
  func rateDuringNativeActivation() async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("native-rate")))
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    fixture.player.setPlaybackRate(1.5)
    #expect(fixture.engine.prepareCount == 0)
    #expect(fixture.engine.playCount == 0)
    try await backend.finishActivation()
    try await waitForVoiceCondition { fixture.player.state.isPlaying }
    #expect(fixture.engine.playCount == 1)
    #expect(fixture.engine.playbackRate == 1.5)
    #expect(fixture.player.state.playbackRate == 1.5)
    #expect(fixture.player.playbackError == nil)
    let backendWasOffMain = await !backend.sawMainThreadTransition
    #expect(backendWasOffMain)
  }

  @Test("remote play admits native startup without claiming that failed activation played audio")
  func remoteNativeActivationFailure() async throws {
    let backend = ControlledAudioSessionBackend()
    let session = InlineAudioSession(backend: backend)
    let fixture = VoiceRequestFixture(audioSession: session)
    defer { fixture.player.stop(); Task { await backend.drain() } }
    try fixture.player.playVoice(for: voiceMessage(1), fileURLOverride: voicePCMFixture())
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    try await backend.finishActivation()
    try await waitForVoiceCondition { fixture.center.isPlaying }
    fixture.player.pause()
    try await waitForSessionCondition { await backend.pendingReleases == 1 }
    try await backend.finishRelease()
    let identity = try #require(fixture.center.remoteCommandIdentity)
    #expect(fixture.center.handleRemoteCommand(.play, expectedIdentity: identity))
    try await waitForSessionCondition { await backend.pendingActivations == 1 }
    #expect(fixture.center.isStarting)
    #expect(!fixture.center.isPlaying)
    #expect(fixture.engine.playCount == 1)
    try await backend.finishActivation(failing: true)
    try await waitForVoiceCondition { fixture.player.playbackError != nil }
    #expect(!fixture.center.isStarting)
    #expect(!fixture.center.isPlaying)
    #expect(fixture.engine.playCount == 1)
    #expect(fixture.center.item?.mediaId == 101)
    #expect(session.current == nil)
  }

  @Test("close, selected cancel, pause and either seek fence pending autoplay",
        arguments: ["close", "cancel", "pause", "seekCurrent", "seekVoice"])
  func pendingIntentInvalidation(action: String) {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    fixture.player.requestVoicePlayback(for: message)
    switch action {
    case "close": fixture.player.stop()
    case "cancel": fixture.player.cancelVoiceSelection(mediaID: 101)
    case "pause": fixture.player.pause()
    case "seekCurrent": fixture.player.seekCurrent(to: 0.5)
    default: fixture.player.seekVoice(to: 0.5, for: message)
    }
    #expect(fixture.downloads.cancelled == [101])
    #expect(fixture.player.loadingVoice == nil)
    fixture.downloads.complete(0, with: .success(requestURL("cancelled")))
    fixture.downloads.complete(0, with: .failure(URLError(.cannotConnectToHost)))
    #expect(fixture.engine.loadCount == 0)
    #expect(fixture.player.state.item == nil)
    #expect(fixture.player.playbackError == nil)
  }

  @Test("cancelling an unrelated transfer preserves selected voice admission")
  func unrelatedCancellation() {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.player.cancelVoiceSelection(mediaID: 999)
    #expect(fixture.downloads.cancelled == [999])
    fixture.downloads.progress(voiceID: 101, received: 75, total: 100)
    #expect(fixture.player.loadingVoice?.progress == 0.75)
    fixture.downloads.complete(0, with: .success(requestURL("selected")))
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.player.state.item?.mediaId == 101)
  }

  @Test("foreground status is checked when download completes", arguments: [false, true])
  func foregroundAtCompletion(foreground: Bool) {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.foreground = !foreground
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.foreground = foreground
    fixture.downloads.complete(0, with: .success(requestURL("completed")))
    #expect(fixture.engine.loadCount == 1)
    #expect(fixture.engine.prepareCount == (foreground ? 1 : 0))
    #expect(fixture.engine.playCount == (foreground ? 1 : 0))
    #expect(fixture.player.state.isPlaying == foreground)
    #expect(fixture.player.state.item?.mediaId == 101)
    #expect(fixture.player.loadingVoice == nil)
    #expect((fixture.center.remoteCommandIdentity != nil) == foreground)
  }

  @Test("background completion prepares a real PCM file without starting it")
  func backgroundPreparesActualAudio() throws {
    let engine = AVAudioPlayerPlaybackEngine()
    let fixture = VoiceRequestFixture(engine: engine)
    defer { fixture.player.stop() }
    fixture.foreground = false
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    let url = try voicePCMFixture()
    fixture.downloads.complete(0, with: .success(url))
    #expect(fixture.player.state.item?.mediaId == 101)
    #expect(fixture.player.state.sourceURL == url)
    #expect(abs(fixture.player.state.duration - 0.5) < 0.01)
    #expect(fixture.player.state.currentTime == 0)
    #expect(!fixture.player.state.isPlaying)
    #expect(!engine.isPlaying)
    #expect(fixture.center.remoteCommandIdentity == nil)
    #expect(fixture.player.playbackError == nil)
  }

  @Test("speed changes while loading preserve admission and apply to the loaded engine")
  func rateWhileLoading() {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.player.setPlaybackRate(2)
    #expect(fixture.player.loadingVoice != nil)
    #expect(fixture.downloads.cancelled.isEmpty)
    #expect(fixture.engine.playCount == 0)
    fixture.downloads.complete(0, with: .success(requestURL("rate")))
    #expect(fixture.engine.playbackRate == 2)
    #expect(fixture.player.state.playbackRate == 2)
    #expect(fixture.player.state.currentTime == 0)
    #expect(fixture.player.state.isPlaying)
  }

  @Test("fresh account authority rejects old completion including same-user replacement", arguments: [Int64(7), 8])
  func freshAccountGeneration(userID: Int64) throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    let previous = try fixture.auth.beginAccountMutation()
    let replacement = try fixture.replaceAccountSynchronously(userID: userID)
    #expect(previous.generation != replacement.generation)
    #expect(previous.userID == 7)
    #expect(replacement.userID == userID)
    // No suspension: the auth observer cannot rescue a missing callback admission check.
    fixture.downloads.complete(0, with: .success(requestURL("old-account")))
    #expect(fixture.engine.loadCount == 0)
    fixture.player.requestVoicePlayback(for: voiceMessage(2)) // First stale selection is rejected.
    #expect(fixture.downloads.completions.count == 1)
    #expect(fixture.player.loadingVoice == nil)
    fixture.player.requestVoicePlayback(for: voiceMessage(2))
    fixture.downloads.complete(1, with: .success(requestURL("new-account")))
    fixture.downloads.complete(0, with: .success(requestURL("old-account")))
    #expect(fixture.player.state.item?.messageId == 2)
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.engine.loadCount == 1)
  }

  @Test("stale same-item cached selection cannot rebind its engine to a fresh account",
        arguments: ["request", "toggle", "prepare"])
  func staleLoadedSelection(action: String) throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    let url = try voicePCMFixture()
    try fixture.player.prepareVoice(for: message, fileURLOverride: url)
    try fixture.player.resumeCurrentPlayback()
    fixture.player.pause()
    fixture.player.seekVoice(to: 0.5, for: message)
    #expect(fixture.player.state.currentTime == 6)
    _ = try fixture.replaceAccountSynchronously(userID: 7)
    // No actor suspension between account replacement and a recycled row's old action.
    switch action {
    case "request": fixture.player.requestVoicePlayback(for: message, fileURLOverride: url)
    case "toggle":
      #expect(throws: AudioPlaybackError.self) {
        try fixture.player.toggleVoicePlayback(for: message, fileURLOverride: url)
      }
    default:
      #expect(throws: AudioPlaybackError.self) {
        try fixture.player.prepareVoice(for: message, fileURLOverride: url)
      }
    }
    #expect(fixture.player.state.item == nil)
    #expect(fixture.player.state.currentTime == 0)
    #expect(fixture.player.state.duration == 0)
    #expect(!fixture.player.state.isPlaying)
    #expect(fixture.engine.loadCount == 1)
    #expect(fixture.engine.playCount == 1)
    fixture.player.requestVoicePlayback(for: voiceMessage(2))
    fixture.downloads.complete(0, with: .success(requestURL("fresh-selection")))
    #expect(fixture.player.state.item?.messageId == 2)
    #expect(fixture.player.state.currentTime == 0)
    #expect(fixture.player.state.isPlaying)
  }

  @Test("the synchronous logout fence rejects completion before snapshot publication")
  func synchronousLogoutFence() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    _ = try fixture.store.beginLogoutSynchronously()
    #expect(fixture.auth.snapshot().status.isAuthenticated)
    fixture.downloads.complete(0, with: .success(requestURL("logout")))
    #expect(fixture.engine.loadCount == 0)
    #expect(fixture.player.state.item == nil)
    fixture.player.requestVoicePlayback(for: voiceMessage(2))
    #expect(fixture.downloads.completions.count == 1)
    #expect(fixture.player.playbackError != nil)
    fixture.player.stop() // Mirrors LogoutPerformer after its synchronous auth fence.
    #expect(fixture.player.loadingVoice == nil)
  }

  @Test("the synchronous logout fence also denies resume of already prepared audio")
  func synchronousLogoutRejectsResume() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.foreground = false
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("prepared")))
    _ = try fixture.store.beginLogoutSynchronously()
    #expect(throws: AudioPlaybackError.self) { try fixture.player.resumeCurrentPlayback() }
    #expect(fixture.engine.playCount == 0)
    #expect(!fixture.player.state.isPlaying)
  }

  @Test("the actual account snapshot observer closes loaded audio after a fresh same-user login")
  func accountObserverClosesLoadedAudio() async throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("loaded")))
    let attempt = try await fixture.store.beginLoginAttempt(allowAuthenticated: true)
    try await fixture.store.saveCredentials(token: "7:fresh-voice-test", userId: 7, loginAttempt: attempt)
    _ = try await fixture.auth.finalizeCredentialsCommittedByLoginAttempt(attempt)
    try await waitForVoiceCondition { fixture.player.state.item == nil }
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.player.loadingVoice == nil)
  }

  @Test("download, load, prepare and start failures expose truthful selection", arguments: ["download", "load", "prepare", "start"])
  func failureTruthfulness(stage: String) {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.engine.failureStage = stage
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: stage == "download"
      ? .failure(URLError(.cannotConnectToHost)) : .success(requestURL("failure")))
    #expect(fixture.player.loadingVoice == nil)
    #expect(fixture.player.playbackError == "Couldn't play this voice message. Try again.")
    #expect(!fixture.player.state.isPlaying)
    #expect((fixture.player.state.item != nil) == (stage == "prepare" || stage == "start"))
    #expect((fixture.player.state.sourceURL != nil) == (stage == "prepare" || stage == "start"))
    #expect(fixture.center.remoteCommandIdentity == nil)
  }

  @Test("an actual corrupt downloaded file leaves idle with a playback error")
  func corruptDownload() throws {
    let fixture = VoiceRequestFixture(engine: AVAudioPlayerPlaybackEngine())
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-request-corrupt-\(UUID()).wav")
    try Data("invalid audio".utf8).write(to: url)
    fixture.downloads.complete(0, with: .success(url))
    #expect(fixture.player.state.item == nil)
    #expect(fixture.player.loadingVoice == nil)
    #expect(fixture.player.playbackError != nil)
  }

  @Test("download cancellation is silent and permits an explicit retry")
  func cancellationAndRetry() {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    fixture.player.requestVoicePlayback(for: message)
    fixture.downloads.complete(0, with: .failure(URLError(.cancelled)))
    #expect(fixture.player.playbackError == nil)
    #expect(fixture.player.loadingVoice == nil)
    #expect(fixture.player.state.item == nil)
    fixture.player.requestVoicePlayback(for: message)
    fixture.downloads.complete(1, with: .success(requestURL("retry")))
    #expect(fixture.player.state.isPlaying)
  }

  @Test("successful retry clears a failed-start error and loaded pause/seek preserve position")
  func successfulRetryAndLoadedControls() throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    let message = voiceMessage(1)
    fixture.engine.failureStage = "start"
    fixture.player.requestVoicePlayback(for: message)
    fixture.downloads.complete(0, with: .success(requestURL("prepared")))
    #expect(fixture.player.playbackError != nil)
    fixture.engine.failureStage = nil
    try fixture.player.resumeCurrentPlayback()
    #expect(fixture.player.state.isPlaying)
    #expect(fixture.player.playbackError == nil)
    fixture.player.pause()
    fixture.player.seekVoice(to: 0.5, for: message)
    #expect(fixture.player.state.currentTime == 6)
    #expect(!fixture.player.state.isPlaying)
    #expect(fixture.engine.playCount == 2)
    try fixture.player.resumeCurrentPlayback()
    #expect(fixture.player.state.currentTime == 6)
    #expect(fixture.player.state.isPlaying)
  }

  @Test("successful remote retry clears the observed core error")
  func successfulRemoteRetry() async throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("remote-retry")))
    fixture.player.pause()
    fixture.engine.failureStage = "start"
    let failedIdentity = try #require(fixture.center.remoteCommandIdentity)
    #expect(!fixture.center.handleRemoteCommand(.play, expectedIdentity: failedIdentity))
    try await waitForVoiceCondition { fixture.player.playbackError != nil }
    #expect(!fixture.player.state.isPlaying)
    fixture.engine.failureStage = nil
    let retryIdentity = try #require(fixture.center.remoteCommandIdentity)
    #expect(fixture.center.handleRemoteCommand(.play, expectedIdentity: retryIdentity))
    try await waitForVoiceCondition { fixture.player.state.isPlaying && fixture.player.playbackError == nil }
  }

  @Test("passive core observation preserves an unrelated request error")
  func passiveObservationPreservesRequestError() async throws {
    let fixture = VoiceRequestFixture()
    defer { fixture.player.stop() }
    fixture.player.requestVoicePlayback(for: voiceMessage(1))
    fixture.downloads.complete(0, with: .success(requestURL("still-playing")))
    var invalid = voiceMessage(2)
    invalid.contentPayload = nil
    fixture.player.requestVoicePlayback(for: invalid)
    #expect(fixture.player.playbackError == AudioPlaybackError.missingVoice.localizedDescription)
    #expect(fixture.player.state.isPlaying)
    fixture.center.setPlaybackRate(1.5)
    try await waitForVoiceCondition { fixture.player.state.playbackRate == 1.5 }
    #expect(fixture.player.playbackError == AudioPlaybackError.missingVoice.localizedDescription)
  }
}

@MainActor
private final class VoiceRequestFixture {
  let cache: AuthSnapshotCache
  let store: AuthStore
  let auth: AuthHandle
  let downloads = ControlledVoiceDownloads()
  let engine: RequestPlaybackEngine
  let center: AudioPlaybackCenter
  var foreground = true
  private(set) var player: SharedAudioPlayer!

  init(engine actualEngine: (any AudioPlaybackEngine)? = nil, audioSession: InlineAudioSession? = nil) {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 7, token: "7:voice-test")), didHydrate: true)
    cache = AuthSnapshotCache(initial: initial)
    store = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString, readSnapshot: { @Sendable _, _, _ in initial })
    auth = AuthHandle(cache: cache, store: store)
    engine = RequestPlaybackEngine()
    center = AudioPlaybackCenter(engine: actualEngine ?? engine,
                                 userDefaults: UserDefaults(suiteName: "VoiceRequestTests-\(UUID())")!,
                                 audioSession: audioSession ?? InlineAudioSession())
    player = SharedAudioPlayer(
      center: center, auth: auth,
      downloadVoice: { [downloads] in downloads.download($0, completion: $1) },
      cancelVoiceDownload: { [downloads] in downloads.cancel($0) },
      voiceProgressPublisher: { [downloads] in downloads.publisher(voiceID: $0) },
      voicePresentation: { message in
        AudioPlaybackPresentation(
          display: AudioPlaybackDisplay(title: "Voice message", parentTitle: "Test chat", senderName: "Sender \(message.messageId)"),
          openTarget: AudioPlaybackOpenTarget(peer: .thread(id: 44), chatId: message.chatId, messageId: message.messageId)
        )
      },
      isForeground: { [weak self] in self?.foreground ?? false }
    )
  }

  func replaceAccountSynchronously(userID: Int64) throws -> AuthAccountMutationToken {
    let attempt = cache.makeLoginAttempt()
    #expect(cache.beginAuthorityStaging(attempt))
    let snapshot = AuthSnapshot(status: .authenticated(AuthCredentials(userId: userID, token: "\(userID):fresh-voice-test")), didHydrate: true)
    #expect(cache.finishAuthorityStaging(snapshot, owner: attempt))
    #expect(cache.prepareStagedAuthorityFinalization(attempt))
    return try #require(cache.finalizeStagedAuthority(attempt, publish: { _ in }))
  }
}

@MainActor
private final class ControlledVoiceDownloads {
  private(set) var completions: [(Result<URL, Error>) -> Void] = []
  private(set) var cancelled: [Int64] = []
  private(set) var publisherRequests: [Int64] = []
  var initialProgress: DownloadProgress?
  var synchronousResult: Result<URL, Error>?
  private var progressSubjects: [Int64: CurrentValueSubject<DownloadProgress, Never>] = [:]
  private var terminalProgress: [Int64: DownloadProgress] = [:]

  func download(_ message: Message, completion: @escaping (Result<URL, Error>) -> Void) {
    completions.append(completion)
    guard let voiceID = message.voiceContent?.voiceID else { return }
    terminalProgress[voiceID] = nil
    let initial = initialProgress ?? DownloadProgress(id: "voice_\(voiceID)", bytesReceived: 0, totalBytes: 0)
    let subject = progressSubjects[voiceID] ?? CurrentValueSubject(initial)
    progressSubjects[voiceID] = subject
    subject.send(initial)
    if let synchronousResult { completion(synchronousResult) }
  }

  func cancel(_ id: Int64) {
    cancelled.append(id)
    progressSubjects.removeValue(forKey: id)?.send(completion: .finished)
    terminalProgress[id] = nil
  }

  // Deliberately deliver even after cancellation, reproducing a queued late callback.
  func complete(_ index: Int, with result: Result<URL, Error>) { completions[index](result) }

  func publisher(voiceID: Int64) -> AnyPublisher<DownloadProgress, Never> {
    publisherRequests.append(voiceID)
    // FileDownloader returns a finished Just for a retained terminal state;
    // starting a retry replaces it with a current-value transfer subject.
    if let terminal = terminalProgress[voiceID] { return Just(terminal).eraseToAnyPublisher() }
    let subject = progressSubjects[voiceID]
      ?? CurrentValueSubject(DownloadProgress(id: "voice_\(voiceID)", bytesReceived: 0, totalBytes: 0))
    progressSubjects[voiceID] = subject
    return subject.eraseToAnyPublisher()
  }

  func progress(voiceID: Int64, received: Int64, total: Int64) {
    progressSubjects[voiceID]?.send(DownloadProgress(id: "voice_\(voiceID)", bytesReceived: received, totalBytes: total))
  }

  func finishProgress(voiceID: Int64, progress: DownloadProgress) {
    terminalProgress[voiceID] = progress
    let subject = progressSubjects.removeValue(forKey: voiceID)
    subject?.send(progress)
    subject?.send(completion: .finished)
  }
}

/// Suspends only the native I/O boundary. The production session retains responsibility
/// for ordering, lease validation, cancellation and completion admission.
private actor ControlledAudioSessionBackend: InlineAudioSessionBackend {
  enum Operation: Equatable, Sendable {
    case activate(InlineAudioSession.Token), release(InlineAudioSession.Token), invalidate
  }

  private enum GateError: Error { case activationFailed, releaseFailed, missingGate }
  private var activations: [CheckedContinuation<Void, Error>] = []
  private var releases: [CheckedContinuation<Void, Error>] = []
  private var isDraining = false
  private(set) var operations: [Operation] = []
  private(set) var sawMainThreadTransition = false
  var pendingActivations: Int { activations.count }
  var pendingReleases: Int { releases.count }
  var didInvalidate: Bool { operations.contains(.invalidate) }

  func activate(token: InlineAudioSession.Token, configuration: InlineAudioSession.Configuration) async throws {
    sawMainThreadTransition = sawMainThreadTransition || Thread.isMainThread
    operations.append(.activate(token))
    guard !isDraining else { return }
    try await withCheckedThrowingContinuation { activations.append($0) }
  }

  func release(token: InlineAudioSession.Token) async throws {
    sawMainThreadTransition = sawMainThreadTransition || Thread.isMainThread
    operations.append(.release(token))
    guard !isDraining else { return }
    try await withCheckedThrowingContinuation { releases.append($0) }
  }

  func invalidate() async { operations.append(.invalidate) }

  func finishActivation(failing: Bool = false) throws {
    guard !activations.isEmpty else { throw GateError.missingGate }
    let continuation = activations.removeFirst()
    if failing { continuation.resume(throwing: GateError.activationFailed) }
    else { continuation.resume() }
  }

  func finishRelease(failing: Bool = false) throws {
    guard !releases.isEmpty else { throw GateError.missingGate }
    let continuation = releases.removeFirst()
    if failing { continuation.resume(throwing: GateError.releaseFailed) }
    else { continuation.resume() }
  }

  func drain() {
    isDraining = true
    let pending = activations + releases
    activations.removeAll()
    releases.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

@MainActor
private final class RequestPlaybackEngine: AudioPlaybackEngine {
  var currentTime: TimeInterval = 0
  var duration: TimeInterval = 12
  var isPlaying = false
  var playbackRate: Float = 1
  var volume: Float = 1
  var onFinish: ((TimeInterval) -> Void)?
  var onFailure: (() -> Void)?
  var failureStage: String?
  private(set) var loadCount = 0
  private(set) var prepareCount = 0
  private(set) var playCount = 0

  func load(contentsOf fileURL: URL) throws {
    loadCount += 1
    if failureStage == "load" { throw AudioPlaybackError.preparationFailed }
    currentTime = 0
  }

  func prepare() throws {
    prepareCount += 1
    if failureStage == "prepare" { throw AudioPlaybackError.preparationFailed }
  }

  func play() -> Bool {
    playCount += 1
    isPlaying = failureStage != "start"
    return isPlaying
  }

  func pause() { isPlaying = false }
  func stop() { isPlaying = false; currentTime = 0 }
  func finishNaturally() {
    isPlaying = false
    currentTime = duration
    onFinish?(duration)
  }
}

private func voiceMessage(_ id: Int64) -> Message {
  var voice = Client_MessageVoiceContent()
  voice.voiceID = id + 100
  voice.duration = 12
  voice.cdnURL = "https://example.invalid/voice/\(id)"
  voice.mimeType = "audio/mp4"
  var payload = Client_MessageContentPayload()
  payload.voice = voice
  return Message(messageId: id, fromId: 7, date: Date(timeIntervalSince1970: 1), text: nil,
                 peerUserId: nil, peerThreadId: 44, chatId: 44, contentPayload: payload)
}

private func requestURL(_ name: String) -> URL { URL(fileURLWithPath: "/voice-request-test/\(name).wav") }

@MainActor
private func waitForVoiceCondition(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
  #expect(condition())
}

@MainActor
private func waitForSessionCondition(_ condition: () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  let satisfied = await condition()
  try #require(satisfied)
}

private func voicePCMFixture() throws -> URL {
  let sampleRate: UInt32 = 8_000
  let sampleCount = 4_000
  let byteCount = UInt32(sampleCount * 2)
  var data = Data()
  func append<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  data.append(contentsOf: "RIFF".utf8); append(byteCount + 36)
  data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
  append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
  data.append(contentsOf: "data".utf8); append(byteCount)
  for sample in 0 ..< sampleCount {
    append(Int16(sin(Double(sample) * 2 * .pi * 440 / Double(sampleRate)) * 1_000))
  }
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-request-pcm-\(UUID()).wav")
  try data.write(to: url)
  return url
}
