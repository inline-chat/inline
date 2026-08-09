import AppKit
import Darwin
import Observation

@MainActor
@Observable
final class InventoryStore {
  private(set) var snapshot = InventorySnapshot.empty
  private(set) var isRefreshing = false
  private(set) var buildStatuses: [String: InventoryBuildStatus] = [:]

  var activeBuildID: String? {
    buildStatuses.first { $0.value.isBuilding }?.key
  }

  func monitor() async {
    await refresh()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      await refresh()
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    snapshot = await InventoryDiscovery.snapshot()
    isRefreshing = false
  }

  func launch(_ item: InventoryItem) {
    guard item.kind.isApplication, let location = item.location else { return }
    NSWorkspace.shared.open(location)
    refreshSoon()
  }

  func build(_ item: InventoryItem) {
    guard let target = item.buildTarget, activeBuildID == nil else { return }
    let startedAt = Date()
    buildStatuses[item.id] = .building(startedAt: startedAt)

    Task { [weak self] in
      let result = await InlineAppBuildRunner.build(target)
      guard let self else { return }
      let elapsed = max(0, Date().timeIntervalSince(startedAt))
      if result.succeeded, let logURL = result.logURL {
        await refreshAfterCurrentRefresh()
        if await relaunchBuiltApplication(itemID: item.id) {
          buildStatuses[item.id] = .succeeded(elapsed: elapsed, logURL: logURL)
        } else {
          buildStatuses[item.id] = .failed(
            "Build succeeded, but the new app could not be launched.",
            elapsed: elapsed,
            logURL: logURL
          )
        }
      } else {
        buildStatuses[item.id] = .failed(
          result.message ?? "Build failed.",
          elapsed: elapsed,
          logURL: result.logURL
        )
        await refreshAfterCurrentRefresh()
      }
    }
  }

  func stop(_ item: InventoryItem) {
    for processID in item.runningProcessIDs {
      if item.kind.isApplication,
         let application = NSRunningApplication(processIdentifier: processID) {
        application.terminate()
      } else if processID != ProcessInfo.processInfo.processIdentifier {
        Darwin.kill(processID, SIGTERM)
      }
    }
    refreshSoon()
  }

  func quit() {
    NSApp.terminate(nil)
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
