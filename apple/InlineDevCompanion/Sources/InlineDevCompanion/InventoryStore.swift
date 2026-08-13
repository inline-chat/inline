import AppKit
import Darwin
import Observation

@MainActor
@Observable
final class InventoryStore {
  static let shared = InventoryStore()

  private(set) var snapshot = InventorySnapshot.empty
  private(set) var isRefreshing = false
  private(set) var buildStatuses: [String: InventoryBuildStatus] = [:]
  private(set) var profilingIDs = Set<String>()
  private(set) var lastActionError: String?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?

  var activeBuildID: String? {
    buildStatuses.first { $0.value.isBuilding }?.key
  }

  func startMonitoring() {
    guard monitorTask == nil else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        do {
          try await Task.sleep(for: .seconds(8))
        } catch {
          return
        }
      }
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    snapshot = await InventoryDiscovery.snapshot()
    isRefreshing = false
  }

  func launch(_ item: InventoryItem) {
    guard item.kind.isMacApplication, let location = item.location else { return }
    NSWorkspace.shared.open(location)
    refreshSoon()
  }

  func build(_ item: InventoryItem) {
    guard let target = item.buildTarget, activeBuildID == nil else { return }
    startBuild(.macOS(target))
  }

  func build(_ device: ConnectedIOSDevice) {
    guard activeBuildID == nil else { return }
    startBuild(.iOS(deviceID: device.id, deviceName: device.name))
  }

  func launch(_ device: ConnectedIOSDevice) {
    Task { [weak self] in
      let result = await DevToolRunner.launch(device)
      self?.record(result)
      await self?.refreshAfterCurrentRefresh()
    }
  }

  func stop(_ device: ConnectedIOSDevice) {
    Task { [weak self] in
      let result = await DevToolRunner.stop(device)
      self?.record(result)
      await self?.refreshAfterCurrentRefresh()
    }
  }

  func reveal(_ item: InventoryItem) {
    guard let location = item.location else { return }
    NSWorkspace.shared.activateFileViewerSelecting([location])
  }

  func profile(_ item: InventoryItem) {
    guard item.kind.isMacApplication,
          let bundleIdentifier = item.bundleIdentifier,
          let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
          ).first?.processIdentifier else {
      lastActionError = "\(item.name) is no longer running."
      refreshSoon()
      return
    }
    startProfile(id: item.id, name: item.name, processID: processID, deviceID: nil)
  }

  func profile(_ device: ConnectedIOSDevice) {
    let id = device.buildID
    guard profilingIDs.insert(id).inserted else { return }
    Task { [weak self] in
      let result = await DevToolRunner.profile(device)
      guard let self else { return }
      profilingIDs.remove(id)
      finishProfile(result)
    }
  }

  func isProfiling(id: String) -> Bool {
    profilingIDs.contains(id)
  }

  func clearActionError() {
    lastActionError = nil
  }

  private func startBuild(_ target: InlineBuildTarget) {
    let logURL: URL
    do {
      logURL = try InlineAppBuildRunner.makeLogURL(for: target)
    } catch {
      buildStatuses[target.id] = .failed(
        "Could not create a build log: \(error.localizedDescription)",
        elapsed: 0,
        logURL: nil
      )
      return
    }

    let startedAt = Date()
    buildStatuses[target.id] = .building(startedAt: startedAt, logURL: logURL)

    Task { [weak self] in
      let result = await InlineAppBuildRunner.build(target, logURL: logURL)
      guard let self else { return }
      let elapsed = max(0, Date().timeIntervalSince(startedAt))
      if result.succeeded, let logURL = result.logURL {
        await refreshAfterCurrentRefresh()
        let didRun: Bool
        switch target {
        case .macOS:
          didRun = await relaunchBuiltApplication(itemID: target.id)
        case .iOS:
          // The repository iOS wrapper installs and launches the selected device build.
          didRun = true
        }
        if didRun {
          buildStatuses[target.id] = .succeeded(elapsed: elapsed, logURL: logURL)
        } else {
          buildStatuses[target.id] = .failed(
            "Build succeeded, but the new app could not be launched.",
            elapsed: elapsed,
            logURL: logURL
          )
        }
      } else {
        buildStatuses[target.id] = .failed(
          result.message ?? "Build failed.",
          elapsed: elapsed,
          logURL: result.logURL
        )
        await refreshAfterCurrentRefresh()
      }
    }
  }

  func stop(_ item: InventoryItem) {
    if item.kind.isMacApplication {
      guard let bundleIdentifier = item.bundleIdentifier else { return }
      for application in NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ) {
        application.terminate()
      }
      refreshSoon()
      return
    }

    Task { [weak self] in
      let processIDs = await InventoryDiscovery.currentProcessIDs(for: item.kind)
      for processID in processIDs where processID != ProcessInfo.processInfo.processIdentifier {
        Darwin.kill(processID, SIGTERM)
      }
      self?.refreshSoon()
    }
  }

  func quit() {
    NSApp.terminate(nil)
  }

  func canTerminateApplication() -> Bool {
    guard activeBuildID == nil, profilingIDs.isEmpty else {
      lastActionError = "Wait for active builds and profiles to finish before quitting the companion."
      return false
    }
    return true
  }

  private func startProfile(
    id: String,
    name: String,
    processID: Int32,
    deviceID: String?
  ) {
    guard profilingIDs.insert(id).inserted else { return }
    Task { [weak self] in
      let result = await DevToolRunner.profile(
        name: name,
        processID: processID,
        deviceID: deviceID
      )
      guard let self else { return }
      profilingIDs.remove(id)
      finishProfile(result)
    }
  }

  private func finishProfile(_ result: DevToolActionResult) {
    record(result)
    if result.succeeded, let traceURL = result.artifactURL {
      NSWorkspace.shared.open(traceURL)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func record(_ result: DevToolActionResult) {
    if result.succeeded {
      lastActionError = nil
    } else {
      lastActionError = result.message ?? "The developer action failed."
    }
  }

  private func refreshSoon() {
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      await self?.refresh()
    }
  }

  private func refreshAfterCurrentRefresh() async {
    while isRefreshing {
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return
      }
    }
    await refresh()
  }

  private func relaunchBuiltApplication(itemID: String) async -> Bool {
    guard let item = snapshot.applications.first(where: { $0.id == itemID }),
          let location = item.location,
          let bundleIdentifier = Bundle(url: location)?.bundleIdentifier else {
      return false
    }

    let runningApplications = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    )
    for application in runningApplications {
      application.terminate()
    }

    for _ in 0..<30 {
      if NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).isEmpty {
        let didOpen = NSWorkspace.shared.open(location)
        if didOpen {
          refreshSoon()
        }
        return didOpen
      }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return false
      }
    }
    return false
  }
}
