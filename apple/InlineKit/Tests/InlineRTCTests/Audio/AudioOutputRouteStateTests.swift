import Testing

@testable import InlineRTC

@Suite("Audio output route state")
struct AudioOutputRouteStateTests {
  @Test("missing preferred output falls back to Auto and restores when it returns")
  func missingPreferenceFallsBackAndRestores() throws {
    var state = AudioOutputRouteState()
    let selection = AudioOutputSelection.device(id: "airpods", rememberedName: "AirPods Pro")
    state.setSelection(selection)
    state.observe(inventory(defaultID: "speakers", devices: [device("speakers")]))

    let fallback = state.desiredResolution
    #expect(fallback?.target == .automatic)
    #expect(fallback?.isFallingBackToAutomatic == true)
    state.routeTransactionSucceeded(try #require(fallback))

    state.observe(
      inventory(
        defaultID: "speakers",
        devices: [device("speakers"), device("airpods", name: "AirPods Pro")]
      )
    )

    #expect(
      state.desiredResolution?.target
        == .device(id: "airpods", name: "AirPods Pro")
    )
    #expect(state.needsRouteTransaction)
    #expect(state.desiredSelection == selection)
  }

  @Test("same UID output format change requires a new transaction")
  func sameUIDProfileChangeRequiresTransaction() throws {
    var state = AudioOutputRouteState()
    state.setSelection(.device(id: "airpods", rememberedName: "AirPods Pro"))
    state.observe(
      inventory(
        defaultID: "airpods",
        devices: [device("airpods", name: "AirPods Pro")],
        sampleRate: 48_000
      )
    )
    state.routeTransactionSucceeded(try #require(state.desiredResolution))

    state.observe(
      inventory(
        defaultID: "airpods",
        devices: [device("airpods", name: "AirPods Pro")],
        sampleRate: 24_000
      )
    )

    #expect(state.needsRouteTransaction)
  }

  @Test("failed explicit output keeps preference and uses verified Auto rollback")
  func explicitFailureKeepsPreference() throws {
    var state = AudioOutputRouteState()
    state.observe(
      inventory(
        defaultID: "speakers",
        devices: [device("speakers"), device("airpods", name: "AirPods Pro")]
      )
    )
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.setSelection(.device(id: "airpods", rememberedName: "AirPods Pro"))
    let failed = try #require(state.desiredResolution)
    state.routeTransactionFailed(failed)
    state.commitResolvedMetadataIfRouteMatches()

    #expect(state.desiredSelection == .device(id: "airpods", rememberedName: "AirPods Pro"))
    #expect(state.desiredResolution?.target == .automatic)
    #expect(state.snapshot?.resolvedOutput.isFallingBackToAutomatic == true)
    #expect(!state.needsRouteTransaction)
  }

  @Test("changed profile retries a quarantined output UID")
  func changedProfileRetriesQuarantinedUID() throws {
    var state = AudioOutputRouteState()
    state.observe(
      inventory(
        defaultID: "speakers",
        devices: [device("speakers"), device("airpods", name: "AirPods Pro")],
        sampleRate: 24_000
      )
    )
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.setSelection(.device(id: "airpods", rememberedName: "AirPods Pro"))
    state.routeTransactionFailed(try #require(state.desiredResolution))
    state.commitResolvedMetadataIfRouteMatches()
    #expect(state.desiredResolution?.target == .automatic)

    state.observe(
      inventory(
        defaultID: "speakers",
        devices: [device("speakers"), device("airpods", name: "AirPods Pro")],
        sampleRate: 48_000
      )
    )

    #expect(
      state.desiredResolution?.target
        == .device(id: "airpods", name: "AirPods Pro")
    )
    #expect(state.needsRouteTransaction)
  }

  @Test("transient output rollback keeps the chosen UID eligible")
  func transientRollbackKeepsPreferenceEligible() throws {
    let preference = AudioOutputSelection.device(
      id: "airpods",
      rememberedName: "AirPods Pro"
    )
    var state = AudioOutputRouteState()
    state.observe(
      inventory(
        defaultID: "speakers",
        devices: [device("speakers"), device("airpods", name: "AirPods Pro")]
      )
    )
    state.routeTransactionSucceeded(try #require(state.desiredResolution))
    state.setSelection(preference)
    let rejected = try #require(state.desiredResolution)

    state.routeTransactionDeferredAfterTransientFailure(rejected)

    #expect(state.desiredSelection == preference)
    #expect(state.desiredResolution?.target == .device(id: "airpods", name: "AirPods Pro"))
    #expect(state.appliedTarget == .automatic)
    #expect(state.needsRouteTransaction)
    #expect(state.snapshot?.resolvedOutput.selection == preference)
    #expect(state.snapshot?.resolvedOutput.activeDeviceID == "speakers")
    #expect(state.snapshot?.resolvedOutput.isFallingBackToAutomatic == true)
  }

  @Test("remembered output name repairs only an unambiguous stable UID")
  func rememberedNameRepairIsUnambiguous() {
    let selection = AudioOutputSelection.device(id: "old", rememberedName: "Studio Display")
    let unique = [device("new", name: "Studio Display")]
    let duplicate = [
      device("one", name: "Studio Display"),
      device("two", name: "Studio Display"),
    ]

    #expect(selection.resolvedDeviceID(in: unique) == "new")
    #expect(selection.resolvedDeviceID(in: duplicate) == nil)
  }

  private func inventory(
    defaultID: String,
    devices: [AudioOutputDeviceDescriptor],
    sampleRate: Double = 48_000
  ) -> AudioOutputDeviceInventory {
    AudioOutputDeviceInventory(
      automaticDeviceID: defaultID,
      automaticDeviceName: devices.first(where: { $0.id == defaultID })?.name ?? "Default",
      devices: devices,
      routeFingerprints: Dictionary(
        uniqueKeysWithValues: devices.map { ($0.id, fingerprint(sampleRate: sampleRate)) }
      ),
      routeEpoch: UInt64(sampleRate)
    )
  }

  private func device(_ id: String, name: String = "Mac Speakers") -> AudioOutputDeviceDescriptor {
    AudioOutputDeviceDescriptor(
      id: id,
      name: name,
      isSystemDefault: id == "speakers",
      systemImage: "speaker.wave.2"
    )
  }

  private func fingerprint(sampleRate: Double) -> AudioOutputRouteFingerprint {
    AudioOutputRouteFingerprint(
      sampleRate: sampleRate,
      channelCount: 2,
      bytesPerPacket: 4,
      framesPerPacket: 1,
      bytesPerFrame: 4,
      bitsPerChannel: 16,
      formatID: 1,
      formatFlags: 0,
      bufferFrameSize: 512,
      transport: 0,
      isAlive: true
    )
  }
}
