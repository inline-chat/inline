import Foundation
import LiveKit
import Testing

@testable import InlineRTC

@Suite("Grid media foundations", .serialized)
@MainActor
struct GridMediaFoundationTests {
  @Test("input preference is independent from a Grid or RTC lifecycle")
  func inputPreferencePersistence() {
    let userDefaults = UserDefaults(suiteName: "GridMediaFoundationTests.\(UUID().uuidString)")!
    let first = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.input.id",
      deviceNameKey: "test.input.name"
    )

    #expect(first.selection == .automatic)
    first.setSelection(.device(id: "external-mic", rememberedName: "Studio Microphone"))

    let restored = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.input.id",
      deviceNameKey: "test.input.name"
    )
    #expect(
      restored.selection
        == .device(id: "external-mic", rememberedName: "Studio Microphone")
    )

    restored.setSelection(.automatic)
    #expect(first.selection == .automatic)
  }

  @Test("output preference is independent from a Grid or RTC lifecycle")
  func outputPreferencePersistence() {
    let userDefaults = UserDefaults(suiteName: "GridMediaFoundationTests.\(UUID().uuidString)")!
    let first = AudioOutputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.output.id",
      deviceNameKey: "test.output.name"
    )

    #expect(first.selection == .automatic)
    first.setSelection(.device(id: "airpods", rememberedName: "AirPods Pro"))

    let restored = AudioOutputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.output.id",
      deviceNameKey: "test.output.name"
    )
    #expect(
      restored.selection == .device(id: "airpods", rememberedName: "AirPods Pro")
    )

    restored.setSelection(.automatic)
    #expect(first.selection == .automatic)
  }

  @Test("voice configuration exposes reviewable LiveKit audio defaults")
  func voiceConfigurationDefaults() {
    let configuration = InlineRTCConfiguration.voice

    #expect(configuration.connection.prepareCloudConnection == false)
    #expect(configuration.connection.publishEnabledMicrophoneDuringConnect == false)
    #expect(configuration.connection.reconnectAttempts >= 120)
    #expect(configuration.connection.singlePeerConnection)
    #expect(configuration.connection.initialConnectSlowWarningDelay > 0)
    #expect(
      configuration.connection.initialConnectWatchdogTimeout
        > configuration.connection.initialConnectSlowWarningDelay
    )
    #expect(configuration.connection.retirementBarrierTimeout > 0)
    #expect(configuration.connection.maxAbandonedProviderOperations == 2)
    let roomOptions = configuration.makeRoomOptions()
    #expect(roomOptions.adaptiveStream)
    #expect(roomOptions.dynacast)
    #expect(roomOptions.defaultScreenShareCaptureOptions.dimensions == .h1080_169)
    #expect(roomOptions.defaultScreenShareCaptureOptions.fps == 15)
    #expect(roomOptions.defaultVideoPublishOptions.screenShareEncoding?.maxBitrate == 2_500_000)
    #expect(roomOptions.defaultVideoPublishOptions.screenShareEncoding?.maxFps == 15)
    #expect(roomOptions.defaultVideoPublishOptions.degradationPreference == .auto)
    #expect(configuration.capture.echoCancellation)
    #expect(configuration.capture.echoCancellationMode == .software)
    #expect(configuration.capture.noiseSuppression)
    #expect(configuration.capture.noiseSuppressionMode == .software)
    let captureOptions = roomOptions.defaultAudioCaptureOptions
    #expect(captureOptions.echoCancellation)
    #expect(captureOptions.echoCancellationMode == .software)
    #expect(captureOptions.noiseSuppression)
    #expect(captureOptions.noiseSuppressionMode == .software)
    #expect(!captureOptions.typingNoiseDetection)
    #expect(configuration.publishing.quality == .speech)
    #expect(configuration.publishing.discontinuousTransmission)
    #expect(configuration.publishing.redundantEncoding)
    #expect(configuration.voiceProcessing.platformVoiceProcessingAllowed == false)
    #expect(configuration.voiceProcessing.bypassed == false)
    #expect(configuration.voiceProcessing.microphoneMuteMode == .inputMixer)
  }

  @Test("screen-share profiles are source-aware and never upscale a small display")
  func screenShareProfilesDoNotUpscale() {
    let source = InlineRTCScreenCaptureSource(
      id: "display:small",
      name: "Small Display",
      displayID: 1,
      pixelDimensions: InlineRTCVideoDimensions(width: 1_366, height: 768)
    )

    for profile in InlineRTCScreenShareQualityProfile.allCases {
      let policy = InlineRTCScreenShareEncodingPolicy.resolve(
        profile: profile,
        source: source
      )
      #expect(policy.dimensions.width <= 1_366)
      #expect(policy.dimensions.height <= 768)
    }
  }

  @Test("screen-share profiles express their resolution, motion, and bandwidth tradeoffs")
  func screenShareProfilePolicies() {
    let source = InlineRTCScreenCaptureSource(
      id: "display:4k",
      name: "4K Display",
      displayID: 2,
      pixelDimensions: InlineRTCVideoDimensions(width: 3_840, height: 2_160)
    )

    let automatic = InlineRTCScreenShareEncodingPolicy.resolve(
      profile: .automatic,
      source: source
    )
    #expect(automatic.dimensions == InlineRTCVideoDimensions(width: 2_560, height: 1_440))
    #expect(automatic.framesPerSecond == 15)
    #expect(automatic.maximumBitrate == 5_000_000)
    #expect(automatic.degradationPolicy == .automatic)

    let detail = InlineRTCScreenShareEncodingPolicy.resolve(profile: .detail, source: source)
    #expect(detail.dimensions == InlineRTCVideoDimensions(width: 2_560, height: 1_440))
    #expect(detail.framesPerSecond == 15)
    #expect(detail.maximumBitrate == 5_000_000)
    #expect(detail.degradationPolicy == .maintainResolution)

    let motion = InlineRTCScreenShareEncodingPolicy.resolve(profile: .motion, source: source)
    #expect(motion.dimensions == InlineRTCVideoDimensions(width: 1_920, height: 1_080))
    #expect(motion.framesPerSecond == 30)
    #expect(motion.maximumBitrate == 5_000_000)
    #expect(motion.degradationPolicy == .maintainFramerate)

    let saveBandwidth = InlineRTCScreenShareEncodingPolicy.resolve(
      profile: .saveBandwidth,
      source: source
    )
    #expect(saveBandwidth.dimensions == InlineRTCVideoDimensions(width: 1_280, height: 720))
    #expect(saveBandwidth.framesPerSecond == 15)
    #expect(saveBandwidth.maximumBitrate == 1_500_000)
    #expect(saveBandwidth.degradationPolicy == .balanced)

    let maximum = InlineRTCScreenShareEncodingPolicy.resolve(profile: .maximum, source: source)
    #expect(maximum.dimensions == InlineRTCVideoDimensions(width: 3_840, height: 2_160))
    #expect(maximum.framesPerSecond == 30)
    #expect(maximum.maximumBitrate == 10_000_000)
    #expect(maximum.degradationPolicy == .maintainResolution)
  }

  @Test("screen-share profile policy reaches LiveKit capture and publish options")
  func screenShareProfileLiveKitOptions() {
    let source = InlineRTCScreenCaptureSource(
      id: "display:4k",
      name: "4K Display",
      displayID: 2,
      pixelDimensions: InlineRTCVideoDimensions(width: 3_840, height: 2_160)
    )

    let options = InlineRTCConfiguration.voice.makeScreenShareOptions(
      source: source,
      profile: .maximum
    )
    #expect(options.capture.dimensions == Dimensions(width: 3_840, height: 2_160))
    #expect(options.capture.fps == 30)
    #expect(options.publish.screenShareEncoding?.maxBitrate == 10_000_000)
    #expect(options.publish.screenShareEncoding?.maxFps == 30)
    #expect(options.publish.degradationPreference == .maintainResolution)
  }

  @Test("local shutdown proof rejects retained microphone or screen publications")
  func shutdownReceiptRequiresNoLocalPublications() {
    let room = GridRTCRoomHandle()
    let retainedScreenShare = GridLocalRoomQuiescenceReceipt(
      room: room,
      localResourcesReleased: true,
      screenSharePublicationCount: 1,
      failures: []
    )
    #expect(!retainedScreenShare.isQuiescent)

    let receipt = GridMediaShutdownReceipt(
      audio: GridAudioShutdownReceipt(
        recordingStopped: true,
        playoutStopped: true,
        mutationReleased: true,
        failures: []
      ),
      rtc: GridRTCShutdownReceipt(
        locallyActiveRoomCount: 0,
        microphonePublicationCount: 1,
        screenSharePublicationCount: 1,
        failures: []
      )
    )
    #expect(!receipt.isLocallyQuiescent)
    #expect(receipt.microphonePublicationCount == 1)
    #expect(receipt.screenSharePublicationCount == 1)
  }

  #if os(macOS)
  @Test("screen-share window sizing preserves landscape, portrait, and ultrawide aspect ratios")
  func screenShareWindowSizing() throws {
    let visibleFrame = CGSize(width: 1280, height: 800)
    let cases = [
      InlineRTCVideoDimensions(width: 1920, height: 1080),
      InlineRTCVideoDimensions(width: 1080, height: 1920),
      InlineRTCVideoDimensions(width: 3440, height: 1440),
    ]

    for dimensions in cases {
      let layout = try #require(InlineRTCScreenShareWindowSizePolicy.layout(
        videoDimensions: dimensions,
        backingScale: 2,
        visibleFrameSize: visibleFrame
      ))
      let expectedAspect = CGFloat(dimensions.width) / CGFloat(dimensions.height)

      #expect(abs(layout.aspectRatio - expectedAspect) < 0.001)
      #expect(abs(layout.initialContentSize.width / layout.initialContentSize.height - expectedAspect) < 0.001)
      #expect(abs(layout.minimumContentSize.width / layout.minimumContentSize.height - expectedAspect) < 0.001)
      #expect(layout.initialContentSize.width <= visibleFrame.width * 0.82)
      #expect(layout.initialContentSize.height <= visibleFrame.height * 0.78)
      #expect(layout.minimumContentSize.width <= layout.initialContentSize.width)
      #expect(layout.minimumContentSize.height <= layout.initialContentSize.height)
    }
  }

  @Test("screen-share window sizing grows a small source without exceeding the screen")
  func smallScreenShareWindowSizing() throws {
    let layout = try #require(InlineRTCScreenShareWindowSizePolicy.layout(
      videoDimensions: InlineRTCVideoDimensions(width: 640, height: 360),
      backingScale: 2,
      visibleFrameSize: CGSize(width: 640, height: 480)
    ))

    #expect(abs(max(layout.initialContentSize.width, layout.initialContentSize.height) - 524.8) < 0.001)
    #expect(layout.initialContentSize.width <= 640 * 0.82)
    #expect(layout.initialContentSize.height <= 480 * 0.78)
  }

  @Test("screen-share window sizing respects Retina natural size and square constraints")
  func screenShareWindowRetinaAndSquareSizing() throws {
    let retinaLayout = try #require(InlineRTCScreenShareWindowSizePolicy.layout(
      videoDimensions: InlineRTCVideoDimensions(width: 1920, height: 1080),
      backingScale: 2,
      visibleFrameSize: CGSize(width: 1440, height: 900)
    ))
    #expect(abs(retinaLayout.initialContentSize.width - 960) < 0.001)
    #expect(abs(retinaLayout.initialContentSize.height - 540) < 0.001)

    let squareLayout = try #require(InlineRTCScreenShareWindowSizePolicy.layout(
      videoDimensions: InlineRTCVideoDimensions(width: 1, height: 1),
      backingScale: 2,
      visibleFrameSize: CGSize(width: 120, height: 80)
    ))
    #expect(abs(squareLayout.aspectRatio - 1) < 0.001)
    #expect(abs(squareLayout.initialContentSize.width - 62.4) < 0.001)
    #expect(abs(squareLayout.initialContentSize.height - 62.4) < 0.001)
    #expect(squareLayout.minimumContentSize == squareLayout.initialContentSize)
  }

  @Test("screen-share renderer exposes the adaptive-stream visibility gate")
  func screenShareRendererVisibility() async {
    let track = LocalVideoTrack.createCameraTrack()
    let share = InlineRTCScreenShare(
      participantIdentity: "test-participant",
      publicationID: "test-publication",
      isLocal: false,
      videoTrack: track
    )
    let view = InlineRTCVideoView(frame: .zero)

    #expect(view.isVideoEnabled)
    view.screenShare = share
    await expectRendererCount(1, on: track)

    view.isVideoEnabled = false
    #expect(!view.isVideoEnabled)
    await expectRendererCount(0, on: track)

    // SwiftUI dismantling clears the share after window-close visibility has
    // already disabled the renderer. This must remain a no-op for attachment.
    view.screenShare = nil
    await expectRendererCount(0, on: track)

    view.isVideoEnabled = true
    #expect(view.isVideoEnabled)
    await expectRendererCount(0, on: track)

    view.screenShare = share
    await expectRendererCount(1, on: track)
    view.screenShare = nil
    await expectRendererCount(0, on: track)
  }

  @Test("screen-share viewer keeps an exact publication amid concurrent shares")
  func screenShareViewerPrefersExactPublication() throws {
    let exact = screenShare(participant: "participant-a", publication: "TR_exact")
    let concurrent = screenShare(
      participant: "participant-a",
      publication: "TR_concurrent"
    )

    let resolved = try #require(InlineRTCScreenShareViewerSelection.resolve(
      publicationID: exact.publicationID,
      participantIdentity: exact.participantIdentity,
      shares: [concurrent, exact]
    ))

    #expect(resolved.publicationID == exact.publicationID)
  }

  @Test("screen-share viewer follows one replacement publication")
  func screenShareViewerFollowsUnambiguousReplacement() throws {
    let replacement = screenShare(
      participant: "participant-a",
      publication: "TR_replacement"
    )
    let otherParticipant = screenShare(
      participant: "participant-b",
      publication: "TR_other"
    )

    let resolved = try #require(InlineRTCScreenShareViewerSelection.resolve(
      publicationID: "TR_replaced",
      participantIdentity: replacement.participantIdentity,
      shares: [otherParticipant, replacement]
    ))

    #expect(resolved.publicationID == replacement.publicationID)
  }

  @Test("screen-share viewer refuses an ambiguous or cross-participant rebind")
  func screenShareViewerRejectsUnsafeReplacement() {
    let first = screenShare(participant: "participant-a", publication: "TR_first")
    let second = screenShare(participant: "participant-a", publication: "TR_second")
    let reusedSID = screenShare(participant: "participant-b", publication: "TR_old")

    #expect(InlineRTCScreenShareViewerSelection.resolve(
      publicationID: "TR_old",
      participantIdentity: "participant-a",
      shares: [first, second, reusedSID]
    ) == nil)
    #expect(InlineRTCScreenShareViewerSelection.resolve(
      publicationID: "TR_old",
      participantIdentity: "participant-a",
      shares: [reusedSID]
    ) == nil)
  }

  private func screenShare(
    participant: String,
    publication: String
  ) -> InlineRTCScreenShare {
    InlineRTCScreenShare(
      participantIdentity: participant,
      publicationID: publication,
      isLocal: false,
      videoTrack: nil
    )
  }

  private func expectRendererCount(
    _ expectedCount: Int,
    on track: LocalVideoTrack
  ) async {
    for _ in 0 ..< 100 {
      guard track.capturer.rendererDelegates.countDelegates != expectedCount else { break }
      await Task.yield()
    }
    #expect(track.capturer.rendererDelegates.countDelegates == expectedCount)
  }
  #endif

  @Test("device snapshot retains an explicit unavailable preference")
  func unavailableDevicePreference() {
    let selection = AudioInputSelection.device(
      id: "disconnected-device",
      rememberedName: "Desk Microphone"
    )
    let snapshot = AudioInputDeviceSnapshot(
      automaticDeviceName: "MacBook Pro Microphone",
      devices: [],
      resolvedInput: ResolvedAudioInput(
        selection: selection,
        activeDeviceID: "built-in",
        activeDeviceName: "MacBook Pro Microphone",
        isFallingBackToAutomatic: true
      )
    )

    #expect(snapshot.resolvedInput.selection == selection)
    #expect(snapshot.resolvedInput.isFallingBackToAutomatic)
    #expect(snapshot.automaticDeviceName == "MacBook Pro Microphone")
  }

  @Test("explicit preference repairs an ID only through an unambiguous inventory")
  func explicitPreferenceMatchesReplacementID() {
    let selection = AudioInputSelection.device(id: "old-id", rememberedName: "Studio Microphone")
    let reconnected = AudioInputDeviceDescriptor(
      id: "new-id",
      name: "Studio Microphone",
      isSystemDefault: false,
      systemImage: "mic.fill"
    )

    #expect(!selection.matches(reconnected))
    #expect(selection.matches(reconnected, among: [reconnected]))
    #expect(selection.resolvedDeviceID(in: [reconnected]) == "new-id")
  }

  @Test("same-name microphones never restore an explicit preference ambiguously")
  func duplicateDeviceNamesAreAmbiguous() {
    let selection = AudioInputSelection.device(id: "old-id", rememberedName: "AirPods")
    let devices = [
      AudioInputDeviceDescriptor(
        id: "first",
        name: "AirPods",
        isSystemDefault: false,
        systemImage: "airpods"
      ),
      AudioInputDeviceDescriptor(
        id: "second",
        name: "AirPods",
        isSystemDefault: false,
        systemImage: "airpods"
      ),
    ]

    #expect(selection.resolvedDeviceID(in: devices) == nil)
  }

  @Test("remembered-name repair ignores harmless case and whitespace changes")
  func rememberedNameRepairIsNormalized() {
    let selection = AudioInputSelection.device(
      id: "old-id",
      rememberedName: "  Studio Microphone "
    )
    let device = AudioInputDeviceDescriptor(
      id: "new-id",
      name: "studio microphone",
      isSystemDefault: false,
      systemImage: "mic.fill"
    )

    #expect(selection.resolvedDeviceID(in: [device]) == "new-id")
  }
}
