import Foundation
import RealtimeV2
import SwiftUI

struct SyncEngineStatsView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var syncStats: SyncStats?
  @State private var isLoadingStats = false

  var body: some View {
    List {
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
    .navigationTitle("Sync Engine Stats")
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

#Preview("Sync Engine Stats") {
  NavigationView {
    SyncEngineStatsView()
  }
}
