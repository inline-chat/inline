import Foundation
import RealtimeV2
import InlineUI
import SwiftUI

struct SyncEngineStatsView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var syncStats: SyncStats?
  @State private var isLoadingStats = false
#if DEBUG || DEBUG_BUILD
  @State private var runningScenario: SyncDebugScenario?
  @State private var runningBucketKey: BucketKey?
  @State private var isCyclingConnection = false
  @State private var actionSummary: String?
  @State private var actionSucceeded = false
#endif

  var body: some View {
    List {
#if DEBUG || DEBUG_BUILD
      Section("Scenarios") {
        Button {
          cycleConnection()
        } label: {
          SyncDebugConnectionRow(isRunning: isCyclingConnection)
        }
        .disabled(isDebugActionRunning)

        ForEach(SyncDebugScenario.allCases) { scenario in
          Button {
            runScenario(scenario)
          } label: {
            SyncDebugScenarioRow(
              scenario: scenario,
              isRunning: runningScenario == scenario
            )
          }
          .disabled(isDebugActionRunning)
        }

        if let actionSummary {
          Text(actionSummary)
            .font(.caption)
            .foregroundStyle(actionSucceeded ? Color.secondary : Color.red)
        }
      }
#endif

      Section("Sync") {
        Button {
          refreshSyncStats()
        } label: {
          SettingsItem(
            icon: "arrow.clockwise",
            iconColor: .blue,
            title: "Refresh Sync Stats"
          ) {
            if isLoadingStats {
              ProgressView()
                .padding(.trailing, 8)
            }
          }
        }

        if let stats = syncStats {
          LabeledContent("Buckets tracked", value: "\(stats.bucketsTracked)")
          LabeledContent("Direct updates applied", value: "\(stats.directUpdatesApplied)")
          LabeledContent("Bucket updates applied", value: "\(stats.bucketUpdatesApplied)")
          LabeledContent("Bucket updates skipped", value: "\(stats.bucketUpdatesSkipped)")
          LabeledContent("Duplicate updates skipped", value: "\(stats.bucketUpdatesDuplicateSkipped)")
          LabeledContent("Bucket fetches", value: "\(stats.bucketFetchCount)")
          LabeledContent("Bucket fetch failures", value: "\(stats.bucketFetchFailures)")
          LabeledContent("Bucket fetch TOO_LONG", value: "\(stats.bucketFetchTooLong)")
          LabeledContent("Bucket fetch follow-ups", value: "\(stats.bucketFetchFollowups)")
          LabeledContent("Buffer recoveries", value: "\(stats.realtimeBufferRecoveries)")
          LabeledContent("Active foreground fetches", value: "\(stats.activeBucketFetches)")
          LabeledContent("Discovery rounds pending", value: "\(stats.discoveryRoundsPending)")
          LabeledContent("Discovery targets pending", value: "\(stats.discoveryTargetsPending)")
          LabeledContent("Discovery targets queued", value: "\(stats.queuedDiscoveryTargets)")
          LabeledContent("State fetch in flight", value: stats.isStateFetchInFlight ? "yes" : "no")
          LabeledContent("State fetch queued", value: stats.hasPendingStateFetch ? "yes" : "no")
          LabeledContent("Last direct apply", value: formatDate(stats.lastDirectApplyAt))
          LabeledContent("Last bucket fetch", value: formatDate(stats.lastBucketFetchAt))
          LabeledContent("Last bucket fetch failure", value: formatDate(stats.lastBucketFetchFailureAt))
          LabeledContent("Last sync date", value: formatDate(stats.lastSyncDate))
        } else {
          Text("No sync stats yet")
            .foregroundStyle(.secondary)
        }
      }

      if let stats = syncStats, !stats.buckets.isEmpty {
        Section("Buckets") {
          ForEach(stats.buckets, id: \.key) { bucket in
            HStack(alignment: .center, spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                let fetchingLabel = bucket.isFetching ? "yes" : "no"
                let pendingLabel = bucket.needsFetch ? "yes" : "no"
                Text(bucketLabel(bucket.key))
                  .font(.body)
                Text("seq \(bucket.seq) | date \(bucket.date) | fetching \(fetchingLabel) | pending \(pendingLabel)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
#if DEBUG || DEBUG_BUILD
              if runningBucketKey == bucket.key {
                ProgressView()
              } else {
                Menu("Stress") {
                  ForEach(SyncDebugBucketScenario.allCases) { scenario in
                    Button(scenario.title) {
                      runBucketScenario(scenario, key: bucket.key)
                    }
                  }
                }
                .disabled(isDebugActionRunning)
              }
#endif
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Sync Engine")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshSyncStats()
    }
  }

  private func refreshSyncStats() {
    isLoadingStats = true
    Task {
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        syncStats = snapshot
        isLoadingStats = false
      }
    }
  }

#if DEBUG || DEBUG_BUILD
  private var isDebugActionRunning: Bool {
    runningScenario != nil || runningBucketKey != nil || isCyclingConnection
  }

  private func runScenario(_ scenario: SyncDebugScenario) {
    runningScenario = scenario
    Task {
      let result = await realtimeV2.runSyncDebugScenario(scenario)
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        actionSummary = result.summary
        actionSucceeded = result.succeeded
        syncStats = snapshot
        runningScenario = nil
      }
    }
  }

  private func runBucketScenario(_ scenario: SyncDebugBucketScenario, key: BucketKey) {
    runningBucketKey = key
    Task {
      let result = await realtimeV2.runSyncDebugBucketScenario(scenario, key: key)
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        actionSummary = result.summary
        actionSucceeded = result.succeeded
        syncStats = snapshot
        runningBucketKey = nil
      }
    }
  }

  private func cycleConnection() {
    isCyclingConnection = true
    Task {
      let result = await realtimeV2.cycleConnectionForSyncDebug()
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        actionSummary = result.summary
        actionSucceeded = result.succeeded
        syncStats = snapshot
        isCyclingConnection = false
      }
    }
  }
#endif

  private func bucketLabel(_ key: BucketKey) -> String {
    switch key {
      case .user:
        return "user"
      case let .space(id):
        return "space \(id)"
      case let .chat(peer):
        switch peer.type {
          case let .chat(value):
            return "chat \(value.chatID)"
          case let .user(value):
            return "dm \(value.userID)"
          default:
            return "chat"
        }
    }
  }

  private func formatDate(_ seconds: Int64) -> String {
    guard seconds > 0 else { return "-" }
    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
    return Self.dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
}

#if DEBUG || DEBUG_BUILD
private struct SyncDebugScenarioRow: View {
  let scenario: SyncDebugScenario
  let isRunning: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: scenario.systemImage)
        .font(.callout)
        .foregroundStyle(.white)
        .scaledFrame(width: 25, height: 25)
        .background(.purple)
        .clipShape(.rect(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 3) {
        Text(scenario.title)
          .foregroundStyle(.primary)
        Text(scenario.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if isRunning {
        ProgressView()
      }
    }
    .padding(.vertical, 2)
  }
}

private struct SyncDebugConnectionRow: View {
  let isRunning: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "network.badge.shield.half.filled")
        .font(.callout)
        .foregroundStyle(.white)
        .scaledFrame(width: 25, height: 25)
        .background(.purple)
        .clipShape(.rect(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 3) {
        Text("Cycle Realtime Connection")
          .foregroundStyle(.primary)
        Text("Stops and reopens the real connection owner, then waits for authenticated open.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if isRunning {
        ProgressView()
      }
    }
    .padding(.vertical, 2)
  }
}
#endif

#Preview("Sync Engine Stats") {
  NavigationView {
    SyncEngineStatsView()
  }
}
