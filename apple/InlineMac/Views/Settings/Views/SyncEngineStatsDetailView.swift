import Foundation
import RealtimeV2
import SwiftUI

struct SyncEngineStatsDetailView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var stats: SyncStats?
  @State private var isLoading = false
#if DEBUG || DEBUG_BUILD
  @State private var runningScenario: SyncDebugScenario?
  @State private var runningBucketKey: BucketKey?
  @State private var isCyclingConnection = false
  @State private var actionSummary: String?
  @State private var actionSucceeded = false
#endif

  var body: some View {
    Form {
#if DEBUG || DEBUG_BUILD
      Section("Scenarios") {
        Button {
          cycleConnection()
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Label("Cycle Realtime Connection", systemImage: "network.badge.shield.half.filled")
              Text("Stops and reopens the real connection owner, then waits up to 15 seconds for authenticated open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isCyclingConnection {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .buttonStyle(.plain)
        .disabled(isDebugActionRunning)

        ForEach(SyncDebugScenario.allCases) { scenario in
          Button {
            runScenario(scenario)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Label(scenario.title, systemImage: scenario.systemImage)
                Text(scenario.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer()
              if runningScenario == scenario {
                ProgressView()
                  .controlSize(.small)
              }
            }
          }
          .buttonStyle(.plain)
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
        HStack {
          Button("Refresh Sync Stats") {
            refreshStats()
          }
          if isLoading {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let stats {
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

      if let stats, !stats.buckets.isEmpty {
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
                  .controlSize(.small)
              } else {
                Menu("Stress") {
                  ForEach(SyncDebugBucketScenario.allCases) { scenario in
                    Button(scenario.title) {
                      runBucketScenario(scenario, key: bucket.key)
                    }
                    .help(scenario.detail)
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
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
    .frame(minWidth: 520, minHeight: 520)
    .navigationTitle("Sync Engine")
    .onAppear {
      refreshStats()
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
        stats = snapshot
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
        stats = snapshot
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
        stats = snapshot
        isCyclingConnection = false
      }
    }
  }
#endif

  private func refreshStats() {
    isLoading = true
    Task {
      let snapshot = await realtimeV2.getSyncStats()
      await MainActor.run {
        stats = snapshot
        isLoading = false
      }
    }
  }

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

#Preview {
  SyncEngineStatsDetailView()
}
