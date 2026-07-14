import Testing

@testable import InlineRTC

@Suite("Audio input routing policy")
struct LiveKitGridAudioDriverTests {
  @Test("AirPods arrival does not rewrite an unchanged explicit preference")
  func airPodsArrivalDoesNotRewriteExplicitRoute() {
    var state = AudioInputRouteState()
    state.observe(inventory(["built-in"]))
    state.setSelection(.device(id: "built-in", rememberedName: "Built-in Microphone"))
    let explicit = state.desiredResolution!
    state.routeTransactionSucceeded(explicit)

    state.observe(inventory(["built-in", "airpods"], epoch: 1))

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
        routeEpoch: 1
      )
    )

    #expect(!state.needsRouteTransaction)
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

  @Test("a failed explicit target is eligible again only after disconnect and return")
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

  private func inventory(
    _ ids: [String],
    epoch: UInt64 = 0
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
      routeEpoch: epoch
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
}
