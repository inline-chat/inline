import Foundation
import RealtimeV2
import SwiftUI

struct SyncEngineStatsDetailView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var stats: SyncStats?
  @State private var isLoading = false

  var body: some View {
    Form {
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
            VStack(alignment: .leading, spacing: 4) {
              Text(bucketLabel(bucket.key))
                .font(.body)
              Text("seq \(bucket.seq) | date \(bucket.date) | fetching \(bucket.isFetching ? \"yes\" : \"no\") | pending \(bucket.needsFetch ? \"yes\" : \"no\")")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
    .frame(minWidth: 520, minHeight: 520)
    .navigationTitle("Sync Engine Stats")
    .onAppear {
      refreshStats()
    }
  }

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
