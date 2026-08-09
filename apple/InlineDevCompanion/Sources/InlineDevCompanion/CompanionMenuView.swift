import SwiftUI

struct CompanionMenuView: View {
  let inventory: InventoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InventorySection(
        title: "Builds",
        items: inventory.snapshot.applications,
        buildStatuses: inventory.buildStatuses,
        activeBuildID: inventory.activeBuildID,
        showsBuildButton: true,
        showsLaunchButton: true,
        onBuild: inventory.build,
        onLaunch: inventory.launch,
        onStop: inventory.stop
      )

      Divider()

      InventorySection(
        title: "Local tools",
        items: inventory.snapshot.tools,
        buildStatuses: [:],
        activeBuildID: nil,
        showsBuildButton: false,
        showsLaunchButton: false,
        onBuild: inventory.build,
        onLaunch: inventory.launch,
        onStop: inventory.stop
      )

      Divider()

      InventoryFooter(
        refreshedAt: inventory.snapshot.refreshedAt,
        isRefreshing: inventory.isRefreshing,
        onRefresh: {
          Task { await inventory.refresh() }
        },
        onQuit: inventory.quit
      )
    }
    .padding(14)
    .frame(width: 460)
    .task {
      await inventory.monitor()
    }
  }
}

private struct InventorySection: View {
  let title: LocalizedStringKey
  let items: [InventoryItem]
  let buildStatuses: [String: InventoryBuildStatus]
  let activeBuildID: String?
  let showsBuildButton: Bool
  let showsLaunchButton: Bool
  let onBuild: (InventoryItem) -> Void
  let onLaunch: (InventoryItem) -> Void
  let onStop: (InventoryItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      ForEach(items) { item in
        InventoryRow(
          item: item,
          buildStatus: buildStatuses[item.id],
          activeBuildID: activeBuildID,
          showsBuildButton: showsBuildButton,
          showsLaunchButton: showsLaunchButton,
          onBuild: onBuild,
          onLaunch: onLaunch,
          onStop: onStop
        )
      }
    }
  }
}

private struct InventoryRow: View {
  let item: InventoryItem
  let buildStatus: InventoryBuildStatus?
  let activeBuildID: String?
  let showsBuildButton: Bool
  let showsLaunchButton: Bool
  let onBuild: (InventoryItem) -> Void
  let onLaunch: (InventoryItem) -> Void
  let onStop: (InventoryItem) -> Void

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
          if item.isRunning {
            Circle()
              .fill(.green)
              .frame(width: 6, height: 6)
              .accessibilityLabel("Running")
          }
        }

        InventoryMetadata(item: item, buildStatus: buildStatus)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if showsBuildButton, item.buildTarget != nil {
        if buildStatus?.isBuilding == true {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .help("Building \(item.name)")
        } else {
          Button("Build", systemImage: "hammer.fill") {
            onBuild(item)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .disabled(activeBuildID != nil)
          .help(buildHelp)
        }
      }

      if showsLaunchButton {
        Button("Launch", systemImage: "play.fill") {
          onLaunch(item)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!item.isInstalled)
        .help(item.isInstalled ? "Launch \(item.name)" : "Build not found")
      }

      if item.isRunning {
        Button("Stop", systemImage: "stop.fill", role: .destructive) {
          onStop(item)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(stopHelp)
      }
    }
  }

  private var stopHelp: String {
    let count = item.runningProcessIDs.count
    return count == 1 ? "Stop \(item.name)" : "Stop \(count) \(item.name) processes"
  }

  private var buildHelp: String {
    switch buildStatus {
    case let .failed(message, _, logURL):
      if let logURL {
        return "\(message) Log: \(logURL.path)"
      }
      return message
    case let .succeeded(_, logURL):
      return "Build \(item.name). Last log: \(logURL.path)"
    case .building:
      return "Building \(item.name)"
    case nil:
      return "Build \(item.name)"
    }
  }
}

private struct InventoryMetadata: View {
  let item: InventoryItem
  let buildStatus: InventoryBuildStatus?

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
          if item.runningProcessIDs.count == 1 {
            Text("running")
          } else {
            Text("\(item.runningProcessIDs.count) running")
          }
        }
      }
      switch buildStatus {
      case let .building(startedAt):
        Text("·")
        Text("building")
        Text(startedAt, style: .timer)
          .monospacedDigit()
      case let .succeeded(elapsed, _):
        Text("·")
        Text("build")
        ElapsedTimeText(elapsed: elapsed)
      case let .failed(message, elapsed, logURL):
        Text("·")
        Text("failed after")
          .foregroundStyle(.red)
          .help(logURL.map { "\(message) Log: \($0.path)" } ?? message)
        ElapsedTimeText(elapsed: elapsed)
          .foregroundStyle(.red)
      case nil:
        EmptyView()
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
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

      Button("Quit", action: onQuit)
        .buttonStyle(.borderless)
    }
    .font(.caption)
  }
}
