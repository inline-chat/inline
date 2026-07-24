import Testing

@testable import InlineRTC

@Suite("Audio input routing policy")
struct LiveKitGridAudioDriverTests {
#if os(macOS)
  @Test("a setter return with stale physical HAL readback does not commit the input UID")
  func staleADMReadbackDoesNotCommit() {
    let snapshot = readbackSnapshot()
    var monitor = MacGridADMDeviceReadbackMonitor(
      expectedUID: "usb-input",
      direction: .input
    )

    let staleMatches = monitor.observe(
      processDeviceIDs: [101],
      isRunning: true,
      snapshot: snapshot
    )
    #expect(!staleMatches)
    #expect(monitor.observedUID == "built-in-input")
    let expectedMatches = monitor.observe(
      processDeviceIDs: [202],
      isRunning: true,
      snapshot: snapshot
    )
    #expect(expectedMatches)
    #expect(monitor.observedUID == "usb-input")
  }

  @Test("temporary empty HAL readback remains pending until the physical route is running")
  func emptyHALReadbackConvergesToPhysicalDefault() {
    let snapshot = readbackSnapshot()
    var monitor = MacGridADMDeviceReadbackMonitor(
      expectedUID: "built-in-input",
      direction: .input
    )

    let emptyMatches = monitor.observe(
      processDeviceIDs: [],
      isRunning: false,
      snapshot: snapshot
    )
    #expect(!emptyMatches)
    #expect(monitor.observedUID == nil)
    let stoppedMatches = monitor.observe(
      processDeviceIDs: [101],
      isRunning: false,
      snapshot: snapshot
    )
    #expect(!stoppedMatches)
    #expect(monitor.observedUID == "built-in-input")
    let defaultMatches = monitor.observe(
      processDeviceIDs: [101],
      isRunning: true,
      snapshot: snapshot
    )
    #expect(defaultMatches)
    #expect(monitor.observedUID == "built-in-input")
  }

  @Test("a fresh callback cannot hide a stale WebRTC graph sample rate")
  func configuredGraphSampleRateMustMatchPhysicalClock() {
    #expect(MacGridAudioGraphFormatHealth.expectedRecordingSampleRate(
      inputSampleRate: 48_000,
      outputSampleRate: 24_000,
      isPlaying: true
    ) == 24_000)
    #expect(MacGridAudioGraphFormatHealth.expectedRecordingSampleRate(
      inputSampleRate: 48_000,
      outputSampleRate: 24_000,
      isPlaying: false
    ) == 48_000)
    #expect(MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: 48_000,
      configuredChannels: 1,
      expectedSampleRate: 48_000,
      isActive: true
    ))
    #expect(!MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: 48_000,
      configuredChannels: 1,
      expectedSampleRate: 24_000,
      isActive: true
    ))
    #expect(!MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: 24_000,
      configuredChannels: 0,
      expectedSampleRate: 24_000,
      isActive: true
    ))
    #expect(MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: 0,
      configuredChannels: 0,
      expectedSampleRate: nil,
      isActive: false
    ))
  }
#endif

  @Test("AirPods arrival does not rewrite an unchanged explicit preference")
  func airPodsArrivalDoesNotRewriteExplicitRoute() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in"]))
    state.setSelection(.device(id: "built-in", rememberedName: "Built-in Microphone"))
    let explicit = state.desiredResolution!
    state.routeTransactionSucceeded(explicit)

    state.observe(inventory(["built-in", "airpods"], epoch: 1, sampleRate: 24_000))

    #expect(!state.needsRouteTransaction)
    #expect(state.desiredResolution?.target == .device(
      id: "built-in",
      name: "Built-in Microphone"
    ))
  }

  @Test("a presentation-only device rename does not rewrite the physical route")
  func deviceRenameDoesNotRewriteRoute() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.setSelection(.device(id: "usb", rememberedName: "USB Microphone"))
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.observe(
      AudioInputDeviceInventory(
        automaticDeviceID: "built-in",
        automaticDeviceName: "Built-in Microphone",
        devices: [
          descriptor(id: "built-in", name: "Built-in Microphone"),
          descriptor(id: "usb", name: "Desk Microphone"),
        ],
        routeFingerprints: [
          "built-in": inputFingerprint(sampleRate: 48_000),
          "usb": inputFingerprint(sampleRate: 48_000),
        ],
        routeEpoch: 1
      )
    )

    #expect(!state.needsRouteTransaction)
  }

  @Test("Auto schedules a route transaction when its physical default changes")
  func automaticPhysicalDeviceChangeSchedulesTransaction() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "airpods"]))
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.observe(
      AudioInputDeviceInventory(
        automaticDeviceID: "airpods",
        automaticDeviceName: "AirPods",
        devices: [
          descriptor(id: "built-in", name: "Built-in Microphone"),
          AudioInputDeviceDescriptor(
            id: "airpods",
            name: "AirPods",
            isSystemDefault: true,
            systemImage: "airpods"
          ),
        ],
        routeFingerprints: [
          "built-in": inputFingerprint(sampleRate: 48_000),
          "airpods": inputFingerprint(sampleRate: 48_000),
        ],
        routeEpoch: 1
      )
    )
    state.commitResolvedMetadataIfRouteMatches()

    #expect(state.needsRouteTransaction)
    #expect(state.snapshot?.resolvedInput.activeDeviceID == "built-in")

    state.routeTransactionSucceeded(state.desiredResolution!)
    #expect(!state.needsRouteTransaction)
    #expect(state.snapshot?.resolvedInput.activeDeviceID == "airpods")
  }

  @Test("missing preferred input falls back once without erasing preference")
  func missingPreferenceFallsBackWithoutBeingErased() {
    let preference = AudioInputSelection.device(
      id: "usb",
      rememberedName: "USB Microphone"
    )
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.setSelection(preference)
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.observe(inventory(["built-in"], epoch: 1))
    #expect(state.needsRouteTransaction)
    #expect(state.desiredResolution?.target == .automatic)
    state.routeTransactionSucceeded(state.desiredResolution!)

    #expect(state.desiredSelection == preference)
    #expect(state.snapshot?.resolvedInput.isFallingBackToAutomatic == true)
    #expect(!state.needsRouteTransaction)
  }

  @Test("preferred input is restored exactly once when it returns")
  func restoredPreferenceReplacesFallback() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in"]))
    state.setSelection(.device(id: "usb", rememberedName: "USB Microphone"))
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.observe(inventory(["built-in", "usb"], epoch: 1))

    #expect(state.needsRouteTransaction)
    #expect(state.desiredResolution?.target == .device(id: "usb", name: "USB Microphone"))
    state.routeTransactionSucceeded(state.desiredResolution!)
    #expect(!state.needsRouteTransaction)
  }

  @Test("Auto remains policy and never becomes a synthetic device ID")
  func automaticIsTypedPolicy() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.setSelection(.device(id: "usb", rememberedName: "USB Microphone"))
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.setSelection(.automatic)

    #expect(state.desiredResolution?.target == .automatic)
    #expect(state.desiredResolution?.activeDeviceID == "built-in")
    #expect(state.needsRouteTransaction)
  }

  @Test("a rejected explicit target becomes a stable Auto fallback")
  func rejectedExplicitTargetFallsBackWithoutLooping() {
    let preference = AudioInputSelection.device(id: "usb", rememberedName: "USB Microphone")
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.setSelection(preference)
    let rejected = state.desiredResolution!

    state.routeTransactionFailed(rejected)

    #expect(state.desiredSelection == preference)
    #expect(state.desiredResolution?.target == .automatic)
    #expect(state.desiredResolution?.isFallingBackToAutomatic == true)
    state.routeTransactionSucceeded(state.desiredResolution!)
    #expect(!state.needsRouteTransaction)

    state.observe(inventory(["built-in", "usb", "airpods"], epoch: 1))
    #expect(state.desiredResolution?.target == .automatic)
    #expect(!state.needsRouteTransaction)
  }

  @Test("verified rollback retains the last applied input route")
  func restoredRouteRetainsAppliedTruth() throws {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "airpods"]))
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    let previouslyApplied = state.appliedResolution

    state.observe(inventory(["built-in", "airpods"], epoch: 1))
    let rejected = try #require(state.desiredResolution)
    state.routeTransactionRestoredAfterFailure(rejected)

    #expect(state.appliedResolution == previouslyApplied)
    #expect(state.appliedTarget == .automatic)
    #expect(state.needsRouteTransaction)
  }

  @Test("a restored Auto route retries only after its physical fingerprint changes")
  func restoredAutomaticRouteRetriesAfterFingerprintChange() throws {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in"], sampleRate: 48_000))
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.observe(inventory(["built-in"], epoch: 1, sampleRate: 24_000))
    state.routeTransactionRestoredAfterFailure(try #require(state.desiredResolution))

    #expect(state.isAutomaticRouteQuarantined)
    state.observe(inventory(["built-in"], epoch: 2, sampleRate: 24_000))
    #expect(state.isAutomaticRouteQuarantined)

    state.observe(inventory(["built-in"], epoch: 3, sampleRate: 48_000))
    #expect(!state.isAutomaticRouteQuarantined)
    #expect(state.needsRouteTransaction)
  }

  @Test("verified explicit rollback quarantines only the rejected preference")
  func restoredExplicitRouteFallsBackWithoutErasingAppliedTruth() throws {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.setSelection(.device(id: "usb", rememberedName: "USB Microphone"))
    let rejected = try #require(state.desiredResolution)

    state.routeTransactionRestoredAfterFailure(rejected)
    state.commitResolvedMetadataIfRouteMatches()

    #expect(state.desiredSelection == .device(id: "usb", rememberedName: "USB Microphone"))
    #expect(state.desiredResolution?.target == .automatic)
    #expect(state.appliedTarget == .automatic)
    #expect(!state.needsRouteTransaction)
  }

  @Test("transient explicit rollback keeps the chosen UID eligible")
  func transientExplicitRollbackKeepsPreferenceEligible() throws {
    let preference = AudioInputSelection.device(
      id: "usb",
      rememberedName: "USB Microphone"
    )
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.setSelection(preference)
    let rejected = try #require(state.desiredResolution)

    state.routeTransactionDeferredAfterTransientFailure(rejected)

    #expect(state.desiredSelection == preference)
    #expect(state.desiredResolution?.target == .device(id: "usb", name: "USB Microphone"))
    #expect(state.appliedTarget == .automatic)
    #expect(state.needsRouteTransaction)
    #expect(state.snapshot?.resolvedInput.selection == preference)
    #expect(state.snapshot?.resolvedInput.activeDeviceID == "built-in")
    #expect(state.snapshot?.resolvedInput.isFallingBackToAutomatic == true)
  }

  @Test("a failed explicit target is eligible again after disconnect and return")
  func rejectedExplicitTargetClearsAfterReconnect() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "usb"]))
    state.setSelection(.device(id: "usb", rememberedName: "USB Microphone"))
    state.routeTransactionFailed(state.desiredResolution!)
    state.routeTransactionSucceeded(state.desiredResolution!)

    state.observe(inventory(["built-in"], epoch: 1))
    #expect(state.desiredResolution?.target == .automatic)
    state.observe(inventory(["built-in", "usb"], epoch: 2))

    #expect(state.desiredResolution?.target == .device(id: "usb", name: "USB Microphone"))
    #expect(state.needsRouteTransaction)
  }

  @Test("a changed input profile retries a quarantined UID")
  func changedInputProfileRetriesQuarantinedUID() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in", "airpods"], sampleRate: 24_000))
    state.routeTransactionSucceeded(state.desiredResolution!)
    state.setSelection(.device(id: "airpods", rememberedName: "AirPods"))
    state.routeTransactionFailed(state.desiredResolution!)
    state.routeTransactionSucceeded(state.desiredResolution!)
    #expect(state.desiredResolution?.target == .automatic)

    state.observe(
      inventory(["built-in", "airpods"], epoch: 1, sampleRate: 48_000)
    )

    #expect(state.desiredResolution?.target == .device(id: "airpods", name: "AirPods"))
    #expect(state.needsRouteTransaction)
  }

  private func inventory(
    _ ids: [String],
    epoch: UInt64 = 0,
    sampleRate: Double = 48_000
  ) -> AudioInputDeviceInventory {
    AudioInputDeviceInventory(
      automaticDeviceID: "built-in",
      automaticDeviceName: "Built-in Microphone",
      devices: ids.map { id in
        AudioInputDeviceDescriptor(
          id: id,
          name: deviceName(id),
          isSystemDefault: id == "built-in",
          systemImage: "mic.fill"
        )
      },
      routeFingerprints: Dictionary(
        uniqueKeysWithValues: ids.map { ($0, inputFingerprint(sampleRate: sampleRate)) }
      ),
      routeEpoch: epoch
    )
  }

  private func inputFingerprint(sampleRate: Double) -> AudioInputRouteFingerprint {
    AudioInputRouteFingerprint(
      sampleRate: sampleRate,
      channelCount: 1,
      bytesPerPacket: 2,
      framesPerPacket: 1,
      bytesPerFrame: 2,
      bitsPerChannel: 16,
      formatID: 1,
      formatFlags: 0,
      bufferFrameSize: 512,
      transport: 0,
      isAlive: true
    )
  }

  private func deviceName(_ id: String) -> String {
    switch id {
    case "built-in": "Built-in Microphone"
    case "usb": "USB Microphone"
    case "airpods": "AirPods"
    default: id
    }
  }

  private func descriptor(id: String, name: String) -> AudioInputDeviceDescriptor {
    AudioInputDeviceDescriptor(
      id: id,
      name: name,
      isSystemDefault: id == "built-in",
      systemImage: "mic.fill"
    )
  }

#if os(macOS)
  private func readbackSnapshot() -> MacGridAudioCatalogSnapshot {
    MacGridAudioCatalogSnapshot(
      devices: [
        MacGridAudioDevice(
          id: 101,
          uid: "built-in-input",
          name: "Built-in Microphone",
          hasInput: true,
          hasOutput: false,
          sampleRate: 48_000,
          bufferFrameSize: 512,
          transport: 0
        ),
        MacGridAudioDevice(
          id: 202,
          uid: "usb-input",
          name: "USB Microphone",
          hasInput: true,
          hasOutput: false,
          sampleRate: 48_000,
          bufferFrameSize: 512,
          transport: 0
        ),
      ],
      defaultInputID: 101,
      defaultOutputID: nil,
      epoch: 1
    )
  }
#endif
}
