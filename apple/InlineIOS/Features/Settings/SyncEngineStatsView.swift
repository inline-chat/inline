import Foundation
import RealtimeV2
import SwiftUI

struct SyncEngineStatsView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var syncStats: SyncStats?
  @State private var isLoadingStats = false
#if DEBUG || DEBUG_BUILD
  @State private var runningScenario: SyncDebugScenario?
  @State private var scenarioResult: SyncDebugScenarioResult?
#endif

  var body: some View {
    List {
#if DEBUG || DEBUG_BUILD
      Section("Scenarios") {
        ForEach(SyncDebugScenario.allCases) { scenario in
          Button {
            runScenario(scenario)
          } label: {
            SyncDebugScenarioRow(
              scenario: scenario,
              isRunning: runningScenario == scenario
            )
          }
          .disabled(runningScenario != nil)
        }

        if let scenarioResult {
          Text(scenarioResult.summary)
            .font(.caption)
            .foregroundStyle(scenarioResult.succeeded ? Color.secondary : Color.red)
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
            VStack(alignment: .leading, spacing: 4) {
              let fetchingLabel = bucket.isFetching ? "yes" : "no"
              let pendingLabel = bucket.needsFetch ? "yes" : "no"
              Text(bucketLabel(bucket.key))
                .font(.body)
              Text("seq \(bucket.seq) | date \(bucket.date) | fetching \(fetchingLabel) | pending \(pendingLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
  private func runScenario(_ scenario: SyncDebugScenario) {
    runningScenario = scenario
    Task {
      let result = await realtimeV2.runSyncDebugScenario(scenario)
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        scenarioResult = result
        syncStats = snapshot
        runningScenario = nil
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
        .frame(width: 25, height: 25)
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
#endif

#Preview("Sync Engine Stats") {
  NavigationView {
    SyncEngineStatsView()
  }
}
