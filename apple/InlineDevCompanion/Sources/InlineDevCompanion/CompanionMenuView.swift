import AppKit
import SwiftUI

enum CompanionDashboardPresentation {
  case menuBar
  case window
}

struct CompanionDashboardView: View {
  @Environment(\.openWindow) private var openWindow

  let inventory: InventoryStore
  let presentation: CompanionDashboardPresentation

  var body: some View {
    Group {
      switch presentation {
      case .menuBar:
        dashboardContent
          .frame(width: 480)
          .fixedSize(horizontal: false, vertical: true)
      case .window:
        ScrollView {
          dashboardContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      inventory.startMonitoring()
    }
  }

  private var dashboardContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let error = inventory.lastActionError {
        ActionErrorBanner(message: error, onDismiss: inventory.clearActionError)
      }

      InventorySection(
        title: "macOS builds",
        items: inventory.snapshot.applications,
        showsBuildButton: true,
        showsLaunchButton: true,
        inventory: inventory
      )

      Divider()

      IOSDeviceSection(
        devices: inventory.snapshot.iOSDevices,
        inventory: inventory
      )

      Divider()

      InventorySection(
        title: "Local tools",
        items: inventory.snapshot.tools,
        showsBuildButton: false,
        showsLaunchButton: false,
        inventory: inventory
      )

      Divider()

      InventoryFooter(
        refreshedAt: inventory.snapshot.refreshedAt,
        isRefreshing: inventory.isRefreshing,
        showsOpenControlPanel: presentation == .menuBar,
        onOpenControlPanel: openControlPanel,
        onRefresh: refresh,
        onQuit: inventory.quit
      )
    }
    .padding(14)
  }

  private func openControlPanel() {
    openWindow(id: "control-panel")
    NSApp.activate(ignoringOtherApps: true)
  }

  private func refresh() {
    Task { await inventory.refresh() }
  }
}

private struct ActionErrorBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      Text(message)
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Dismiss", systemImage: "xmark", action: onDismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .padding(10)
    .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
  }
}

private struct InventorySection: View {
  let title: LocalizedStringKey
  let items: [InventoryItem]
  let showsBuildButton: Bool
  let showsLaunchButton: Bool
  let inventory: InventoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      ForEach(items) { item in
        InventoryRow(
          item: item,
          buildStatus: inventory.buildStatuses[item.id],
          activeBuildID: inventory.activeBuildID,
          isProfiling: inventory.isProfiling(id: item.id),
          showsBuildButton: showsBuildButton,
          showsLaunchButton: showsLaunchButton,
          onBuild: inventory.build,
          onLaunch: inventory.launch,
          onStop: inventory.stop,
          onReveal: inventory.reveal,
          onProfile: inventory.profile
        )
      }
    }
  }
}

private struct InventoryRow: View {
  @Environment(\.openWindow) private var openWindow

  let item: InventoryItem
  let buildStatus: InventoryBuildStatus?
  let activeBuildID: String?
  let isProfiling: Bool
  let showsBuildButton: Bool
  let showsLaunchButton: Bool
  let onBuild: (InventoryItem) -> Void
  let onLaunch: (InventoryItem) -> Void
  let onStop: (InventoryItem) -> Void
  let onReveal: (InventoryItem) -> Void
  let onProfile: (InventoryItem) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.systemImage)
        .frame(width: 18)
        .foregroundStyle(item.isInstalled ? .primary : .tertiary)
        .help(item.location?.path ?? "Not installed")

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.name)
            .lineLimit(1)
          RunningIndicator(isRunning: item.isRunning)
        }

        InventoryMetadata(
          item: item,
          buildStatus: buildStatus,
          isProfiling: isProfiling
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if showsBuildButton, item.buildTarget != nil {
        BuildButton(
          name: item.name,
          status: buildStatus,
          activeBuildID: activeBuildID,
          onBuild: build
        )
      }

      if let logURL = buildStatus?.logURL {
        BuildLogButton(logURL: logURL, onOpen: openBuildLog)
      }

      if showsLaunchButton {
        Button("Run", systemImage: "play.fill", action: launch)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .disabled(!item.isInstalled)
          .help(item.isInstalled ? "Run \(item.name)" : "Build not found")
      }

      if item.isRunning {
        Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help(stopHelp)
      }

      Menu {
        actions
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Developer actions for \(item.name)")
    }
    .contentShape(.rect)
    .contextMenu {
      actions
    }
  }

  @ViewBuilder
  private var actions: some View {
    if showsLaunchButton {
      Button("Run", systemImage: "play.fill", action: launch)
        .disabled(!item.isInstalled)
    }
    if showsBuildButton, item.buildTarget != nil {
      Button("Build and Run", systemImage: "hammer.fill", action: build)
        .disabled(activeBuildID != nil)
    }
    if let logURL = buildStatus?.logURL {
      Button("Open Build Log", systemImage: "doc.text.magnifyingglass") {
        openBuildLog(logURL)
      }
      Button("Show Build Log in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
      }
    }
    if item.isRunning, item.kind.isMacApplication {
      Divider()
      Button(
        isProfiling ? "Recording Time Profile…" : "Time Profile in Instruments (30s)",
        systemImage: "gauge.with.dots.needle.67percent",
        action: profile
      )
      .disabled(isProfiling)
    }
    if item.location != nil {
      Divider()
      Button("Show in Finder", systemImage: "folder", action: reveal)
    }
    if item.isRunning {
      Divider()
      Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
    }
  }

  private var stopHelp: String {
    let count = item.runningProcessIDs.count
    return count == 1 ? "Stop \(item.name)" : "Stop \(count) \(item.name) processes"
  }

  private func build() {
    onBuild(item)
  }

  private func launch() {
    onLaunch(item)
  }

  private func stop() {
    onStop(item)
  }

  private func reveal() {
    onReveal(item)
  }

  private func profile() {
    onProfile(item)
  }

  private func openBuildLog(_ logURL: URL) {
    openWindow(value: logURL.path)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct IOSDeviceSection: View {
  let devices: [ConnectedIOSDevice]
  let inventory: InventoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("iOS devices")
        .font(.headline)

      if devices.isEmpty {
        Text("Connect and unlock a paired iPhone with Developer Mode enabled.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(devices) { device in
          IOSDeviceRow(
            device: device,
            buildStatus: inventory.buildStatuses[device.buildID],
            activeBuildID: inventory.activeBuildID,
            isProfiling: inventory.isProfiling(id: device.buildID),
            onBuild: inventory.build,
            onLaunch: inventory.launch,
            onStop: inventory.stop,
            onProfile: inventory.profile
          )
        }
      }
    }
  }
}

private struct IOSDeviceRow: View {
  @Environment(\.openWindow) private var openWindow

  let device: ConnectedIOSDevice
  let buildStatus: InventoryBuildStatus?
  let activeBuildID: String?
  let isProfiling: Bool
  let onBuild: (ConnectedIOSDevice) -> Void
  let onLaunch: (ConnectedIOSDevice) -> Void
  let onStop: (ConnectedIOSDevice) -> Void
  let onProfile: (ConnectedIOSDevice) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "iphone")
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("Inline iOS — \(device.name)")
            .lineLimit(1)
          RunningIndicator(isRunning: device.isRunning)
        }
        IOSDeviceMetadata(
          device: device,
          buildStatus: buildStatus,
          isProfiling: isProfiling
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      BuildButton(
        name: "Inline iOS on \(device.name)",
        status: buildStatus,
        activeBuildID: activeBuildID,
        onBuild: build
      )

      if let logURL = buildStatus?.logURL {
        BuildLogButton(logURL: logURL, onOpen: openBuildLog)
      }

      Button("Run", systemImage: "play.fill", action: launch)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(device.installedApplication == nil)
        .help(device.installedApplication == nil ? "Inline Debug is not installed" : "Run on \(device.name)")

      if device.isRunning {
        Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Stop Inline on \(device.name)")
      }

      Menu {
        actions
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Developer actions for Inline on \(device.name)")
    }
    .contentShape(.rect)
    .contextMenu {
      actions
    }
  }

  @ViewBuilder
  private var actions: some View {
    Button("Run", systemImage: "play.fill", action: launch)
      .disabled(device.installedApplication == nil)
    Button("Build, Install, and Run", systemImage: "hammer.fill", action: build)
      .disabled(activeBuildID != nil)
    if let logURL = buildStatus?.logURL {
      Button("Open Build Log", systemImage: "doc.text.magnifyingglass") {
        openBuildLog(logURL)
      }
      Button("Show Build Log in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
      }
    }
    if device.isRunning {
      Divider()
      Button(
        isProfiling ? "Recording Time Profile…" : "Time Profile in Instruments (30s)",
        systemImage: "gauge.with.dots.needle.67percent",
        action: profile
      )
      .disabled(isProfiling)
      Divider()
      Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
    }
  }

  private func build() {
    onBuild(device)
  }

  private func launch() {
    onLaunch(device)
  }

  private func stop() {
    onStop(device)
  }

  private func profile() {
    onProfile(device)
  }

  private func openBuildLog(_ logURL: URL) {
    openWindow(value: logURL.path)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct RunningIndicator: View {
  let isRunning: Bool

  var body: some View {
    if isRunning {
      Circle()
        .fill(.green)
        .frame(width: 6, height: 6)
        .accessibilityLabel("Running")
    }
  }
}

private struct BuildButton: View {
  let name: String
  let status: InventoryBuildStatus?
  let activeBuildID: String?
  let onBuild: () -> Void

  var body: some View {
    if status?.isBuilding == true {
      ProgressView()
        .controlSize(.small)
        .frame(width: 16, height: 16)
        .help("Building \(name)")
    } else {
      Button("Build and Run", systemImage: "hammer.fill", action: onBuild)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(activeBuildID != nil)
        .help(buildHelp)
    }
  }

  private var buildHelp: String {
    switch status {
    case let .failed(message, _, logURL):
      if let logURL {
        return "\(message) Log: \(logURL.path)"
      }
      return message
    case let .succeeded(_, logURL):
      return "Build and run \(name). Last log: \(logURL.path)"
    case .building:
      return "Building \(name)"
    case nil:
      return "Build and run \(name)"
    }
  }
}

private struct BuildLogButton: View {
  let logURL: URL
  let onOpen: (URL) -> Void

  var body: some View {
    Button("Open Build Log", systemImage: "doc.text.magnifyingglass") {
      onOpen(logURL)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .help("Open live build log")
  }
}

private struct InventoryMetadata: View {
  let item: InventoryItem
  let buildStatus: InventoryBuildStatus?
  let isProfiling: Bool

  var body: some View {
    HStack(spacing: 4) {
      if !item.isInstalled {
        Text("Not found")
      } else {
        if let version = item.version {
          Text(version)
          if item.modifiedAt != nil {
            Text("·")
          }
        }
        if let modifiedAt = item.modifiedAt {
          Text("built")
          Text(modifiedAt, style: .relative)
        }
        if item.isRunning {
          Text("·")
          Text(item.runningProcessIDs.count == 1 ? "running" : "\(item.runningProcessIDs.count) running")
        }
      }
      BuildStatusMetadata(status: buildStatus)
      if isProfiling {
        Text("· profiling 30s")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}

private struct IOSDeviceMetadata: View {
  let device: ConnectedIOSDevice
  let buildStatus: InventoryBuildStatus?
  let isProfiling: Bool

  var body: some View {
    HStack(spacing: 4) {
      if let version = device.installedApplication?.displayVersion {
        Text(version)
        Text("installed")
      } else {
        Text("Not installed")
      }
      if let osVersion = device.osVersion {
        Text("· iOS \(osVersion)")
      }
      if let connection = device.connectionTransport {
        Text("· \(connection)")
      }
      if let processID = device.runningProcessID {
        Text("· running · PID \(processID)")
      }
      BuildStatusMetadata(status: buildStatus)
      if isProfiling {
        Text("· profiling 30s")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .help(device.model ?? "Physical iOS device")
  }
}

private struct BuildStatusMetadata: View {
  let status: InventoryBuildStatus?

  var body: some View {
    switch status {
    case let .building(startedAt, _):
      Text("· building")
      Text(startedAt, style: .timer)
        .monospacedDigit()
    case let .succeeded(elapsed, _):
      Text("· build")
      ElapsedTimeText(elapsed: elapsed)
    case let .failed(message, elapsed, logURL):
      Text("· failed after")
        .foregroundStyle(.red)
        .help(logURL.map { "\(message) Log: \($0.path)" } ?? message)
      ElapsedTimeText(elapsed: elapsed)
        .foregroundStyle(.red)
    case nil:
      EmptyView()
    }
  }
}

private struct ElapsedTimeText: View {
  let elapsed: TimeInterval

  var body: some View {
    if elapsed >= 3_600 {
      Text(Duration.seconds(elapsed), format: .time(pattern: .hourMinuteSecond))
    } else {
      Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
    }
  }
}

private struct InventoryFooter: View {
  let refreshedAt: Date
  let isRefreshing: Bool
  let showsOpenControlPanel: Bool
  let onOpenControlPanel: () -> Void
  let onRefresh: () -> Void
  let onQuit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help("Refresh inventory")

      if refreshedAt != .distantPast {
        Text("Updated")
          .foregroundStyle(.secondary)
        Text(refreshedAt, style: .relative)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if showsOpenControlPanel {
        Button("Open Control Panel", systemImage: "macwindow", action: onOpenControlPanel)
          .buttonStyle(.borderless)
      }

      Button("Quit", action: onQuit)
        .buttonStyle(.borderless)
    }
    .font(.caption)
  }
}
