import Auth
import Foundation
import GRDB
import InlineConfig
import InlineIOSUI
import InlineKit
import InlineProtocol
import Testing
import UIKit
@testable import InlineIOS

@Suite("Physical paused voice pill component demo", .serialized)
@MainActor
struct VoicePlaybackPillDeviceDemoTests {
  @Test("Synthetic paused voice coexists above a real pinned header",
        .enabled(if: ProcessInfo.processInfo.environment["INLINE_DEVICE_VOICE_PILL_DEMO"] == "1"))
  func pausedComponentDemo() async throws {
    // Check isolation before constructing shared auth, database, or player state.
    let isTestProcess = TestProcess.isRunning
    try #require(isTestProcess)
    #if targetEnvironment(simulator)
    let isPhysicalDevice = false
    #else
    let isPhysicalDevice = true
    #endif
    try #require(isPhysicalDevice, "This opt-in component demo requires a physical iPhone.")
    let authIsIsolated = !Auth.shared.getIsLoggedIn() && Auth.shared.getCurrentUserId() == nil
    try #require(authIsIsolated)
    let databaseIsIsolated = !AppDatabase.shared.isPersistent
    try #require(databaseIsIsolated)
    let applicationIsActive = UIApplication.shared.applicationState == .active
    try #require(applicationIsActive)
    let activeScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    let scene = try #require(activeScene)
    let sessionIsVacant = InlineAudioSession.shared.current == nil
    try #require(sessionIsVacant)
    let player = SharedAudioPlayer.shared
    let center = AudioPlaybackCenter.shared
    let voiceIsIdle = !player.isVoiceSelected && center.item == nil && !center.isPlaying
    try #require(voiceIsIdle)

    let fixtureID = Int64.random(in: 8_000_000_000 ... 8_999_999_999)
    let pinnedID: Int64 = 1
    let voiceID: Int64 = 2
    try seed(chatID: fixtureID, pinnedID: pinnedID, voiceID: voiceID)
    // Use exactly the production header query before attaching a view. A missing
    // FullMessage would cause TargetMessagesFetcher; this test forbids that path.
    let pinned = try await AppDatabase.shared.dbWriter.read { db in
      try FullMessage.queryRequest()
        .filter(Column("messageId") == pinnedID && Column("chatId") == fixtureID)
        .fetchOne(db)
    }
    let fullPin = try #require(pinned)
    #expect(fullPin.message.text == "Keep the pin while a voice message is selected.")
    #expect(fullPin.from?.id == fixtureID)

    let runID = UUID().uuidString
    let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
      .appendingPathComponent("InlineVoicePillDemo-\(runID)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let audioURL = directory.appendingPathComponent("synthetic-paused.wav")
    try writeSilentWAV(to: audioURL)

    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    controller.title = "Voice + pin component demo"
    controller.view.backgroundColor = .systemGroupedBackground
    let navigation = UINavigationController(rootViewController: controller)
    window.rootViewController = navigation
    defer {
      center.close()
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
      // Keep only our synthetic rows/files. The in-memory test process is discarded.
    }
    try center.prepare(
      fileURL: audioURL,
      item: AudioPlaybackItem(kind: .voice, chatId: fixtureID, messageId: voiceID, mediaId: fixtureID),
      presentation: AudioPlaybackPresentation(
        display: AudioPlaybackDisplay(title: "Voice message from Maya", parentTitle: "Design team", senderName: "Maya"),
        openTarget: AudioPlaybackOpenTarget(peer: .thread(id: fixtureID), chatId: fixtureID, messageId: voiceID)
      )
    )
    try await waitForSelection(player, selected: true)
    let header = PinnedMessageHeaderView(peerId: .thread(id: fixtureID), chatId: fixtureID)
    controller.view.addSubview(header)
    let height = header.heightAnchor.constraint(equalToConstant: 0)
    header.onHeightChange = { height.constant = $0 }
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
      header.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
      height,
    ])
    let explanation = UILabel()
    explanation.text = "Paused component demo\nSynthetic local data only\nNo playback, chat navigation, composer, background or Lock Screen proof."
    explanation.numberOfLines = 0
    explanation.font = .preferredFont(forTextStyle: .footnote)
    explanation.adjustsFontForContentSizeCategory = true
    explanation.textColor = .secondaryLabel
    explanation.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(explanation)
    NSLayoutConstraint.activate([
      explanation.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
      explanation.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
      explanation.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
    ])
    window.makeKeyAndVisible()

    for (name, category, direction) in [
      ("normal", UIContentSizeCategory.large, UITraitEnvironmentLayoutDirection.leftToRight),
      ("accessibility-xxxl", .accessibilityExtraExtraExtraLarge, .leftToRight),
      ("rtl-accessibility-xxxl", .accessibilityExtraExtraExtraLarge, .rightToLeft),
    ] {
      controller.traitOverrides.preferredContentSizeCategory = category
      controller.traitOverrides.layoutDirection = direction
      controller.view.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
      try await settle(window)
      #expect(header.traitCollection.preferredContentSizeCategory == category)
      #expect(header.traitCollection.layoutDirection == direction)
      try checkCoexistence(header, window: window)
      try snapshot(window, name: name, directory: directory)
      if name == "normal" {
        #expect(center.seek(to: 0.04))
        try await settle(window)
        try snapshot(window, name: "early-progress", directory: directory)
        #expect(center.seek(to: 0))
      }
    }

    controller.traitOverrides.preferredContentSizeCategory = .large
    controller.traitOverrides.layoutDirection = .leftToRight
    controller.view.semanticContentAttribute = .forceLeftToRight
    center.close()
    try await waitForSelection(player, selected: false)
    try await settle(window)
    let pin = try nativeButton("Open pinned message", in: header)
    let unpin = try nativeButton("Unpin message", in: header)
    #expect(!header.isHidden && header.alpha > 0.99)
    #expect(abs(header.bounds.height - PinnedMessageHeaderView.preferredHeight) < 1)
    #expect(pin.frame.height >= 44 && unpin.frame.width >= 44 && unpin.frame.height >= 44)
    let pinRemains = try await AppDatabase.shared.dbWriter.read { db in
      try PinnedMessage.isPinned(db, chatId: fixtureID, messageId: pinnedID)
    }
    #expect(pinRemains)
    let ownerIsVacantAfterClose = InlineAudioSession.shared.current == nil
    #expect(ownerIsVacantAfterClose)
    try snapshot(window, name: "closed-pin-remains", directory: directory)
    print("[VoicePillComponent] componentOnly=true paused=true ownerVacant=\(ownerIsVacantAfterClose) relativeDirectory=Documents/InlineVoicePillDemo-\(runID)")
  }
}

@MainActor
private extension VoicePlaybackPillDeviceDemoTests {
  func seed(chatID: Int64, pinnedID: Int64, voiceID: Int64) throws {
    try AppDatabase.shared.dbWriter.write { db in
      try User(id: chatID, email: nil, firstName: "Maya").insert(db)
      try Chat(id: chatID, date: .now, type: .thread, title: "Design team", spaceId: nil).insert(db)
      try Message(messageId: pinnedID, fromId: chatID, date: .now,
                  text: "Keep the pin while a voice message is selected.",
                  peerUserId: nil, peerThreadId: chatID, chatId: chatID, pinned: true).insert(db)
      let voicePayload = Client_MessageContentPayload.with {
        $0.voice = Client_MessageVoiceContent.with {
          $0.voiceID = chatID
          $0.duration = 12
          $0.mimeType = "audio/wav"
        }
      }
      try Message(messageId: voiceID, fromId: chatID, date: .now, text: nil,
                  peerUserId: nil, peerThreadId: chatID, chatId: chatID, contentPayload: voicePayload).insert(db)
      try PinnedMessage(chatId: chatID, messageId: pinnedID, position: 0).insert(db)
    }
  }

  func writeSilentWAV(to url: URL) throws {
    let sampleRate: UInt32 = 8_000
    let byteCount: UInt32 = sampleRate * 12 * 2
    var data = Data()
    func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
    func little<T: FixedWidthInteger>(_ value: T) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    ascii("RIFF"); little(byteCount + 36); ascii("WAVEfmt "); little(UInt32(16))
    little(UInt16(1)); little(UInt16(1)); little(sampleRate); little(sampleRate * 2)
    little(UInt16(2)); little(UInt16(16)); ascii("data"); little(byteCount)
    data.append(Data(repeating: 0, count: Int(byteCount)))
    try data.write(to: url, options: .atomic)
  }

  func waitForSelection(_ player: SharedAudioPlayer, selected: Bool) async throws {
    for _ in 0 ..< 40 {
      if player.isVoiceSelected == selected { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    let reachedSelection = player.isVoiceSelected == selected
    try #require(reachedSelection, "Shared facade did not observe the paused component selection.")
  }

  func settle(_ window: UIWindow) async throws {
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
  }

  func nativeButton(_ label: String, in view: UIView) throws -> UIButton {
    let matches = descendants(view).compactMap { $0 as? UIButton }.filter { $0.accessibilityLabel == label }
    let uniqueMatch = matches.count == 1
    try #require(uniqueMatch)
    return try #require(matches.first)
  }

  func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  func checkCoexistence(_ header: PinnedMessageHeaderView, window: UIWindow) throws {
    let pin = try nativeButton("Open pinned message", in: header)
    let unpin = try nativeButton("Unpin message", in: header)
    let pinContainer = try #require(pin.superview)
    let voice = try #require(header.subviews.first { $0 !== pinContainer })
    let voiceFrame = voice.convert(voice.bounds, to: window)
    let pinFrame = pin.convert(pin.bounds, to: window)
    let expectedVoiceHeight = VoicePlaybackPill.preferredHeight(compatibleWith: header.traitCollection)
    #expect(!header.isHidden && header.alpha > 0.99 && !voice.isHidden)
    #expect(abs(header.bounds.height - header.displayedHeight) < 1)
    #expect(abs(voiceFrame.height - expectedVoiceHeight) < 1)
    #expect(voiceFrame.maxY <= pinFrame.minY)
    #expect(window.bounds.contains(voiceFrame) && window.bounds.contains(pinFrame))
    #expect(unpin.frame.width >= 44 && unpin.frame.height >= 44)
    let remainsPaused = !AudioPlaybackCenter.shared.isPlaying && SharedAudioPlayer.shared.state.duration >= 12
    let ownsNoSession = InlineAudioSession.shared.current == nil
    #expect(remainsPaused && ownsNoSession)
    print("[VoicePillComponent] headerHeight=\(header.bounds.height) voiceFrame=\(voiceFrame) pinFrame=\(pinFrame) unpinSize=\(unpin.bounds.size) paused=\(remainsPaused) ownerVacant=\(ownsNoSession)")
  }

  func snapshot(_ window: UIWindow, name: String, directory: URL) throws {
    var drewHierarchy = false
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try #require(drewHierarchy)
    let png = try #require(image.pngData())
    try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    Attachment.record(Array(png), named: "voice-pill-component-\(name).png")
  }
}
