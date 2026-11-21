import GRDB
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

/// Read-only plan status. Purchases and plan changes aren't offered in the iOS app.
struct PlanSettingsView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var model = PlanSettingsModel()

  var body: some View {
    List {
      if let billing = model.billing {
        Section("Your Plan") {
          accountRows(billing.me)
        }
        if !billing.spaces.isEmpty {
          Section("Spaces You Manage") {
            ForEach(billing.spaces, id: \.spaceID) { account in
              VStack(alignment: .leading, spacing: 2) {
                Text(model.spaceNames[account.spaceID] ?? "Space")
                Text(status(account))
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                if account.hasWallet {
                  Text("Credit: \(BillingFormat.wallet(account.wallet))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      } else if model.failed {
        Section {
          Text("Your plan couldn't be loaded. Check your connection and try again.")
            .foregroundStyle(.secondary)
          Button("Try Again") { Task { await model.load(realtimeV2) } }
        }
      } else {
        Section {
          HStack(spacing: 8) {
            ProgressView()
            Text("Loading your plan…").foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("Plan")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load(realtimeV2) }
    .refreshable { await model.load(realtimeV2) }
  }

  @ViewBuilder
  private func accountRows(_ account: BillingAccount) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(account.isPro && account.hasSubscription
        ? BillingFormat.planTitle(account.subscription.plan, interval: account.subscription.interval)
        : "Free")
      if account.isPro, account.hasSubscription {
        Text(BillingFormat.status(account.subscription))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    if account.hasWallet {
      LabeledContent("Credit", value: BillingFormat.wallet(account.wallet))
    }
  }

  private func status(_ account: BillingAccount) -> String {
    guard account.isPro, account.hasSubscription else { return "Free" }
    let sub = account.subscription
    return "\(BillingFormat.planTitle(sub.plan, interval: sub.interval)) · \(BillingFormat.status(sub))"
  }
}

@MainActor
@Observable
final class PlanSettingsModel {
  private static var cached: GetBillingResult?
  private static var cachedSpaceNames: [Int64: String] = [:]

  private let log = Log.scoped("PlanSettings")
  private(set) var billing: GetBillingResult? = PlanSettingsModel.cached
  private(set) var spaceNames: [Int64: String] = PlanSettingsModel.cachedSpaceNames
  private(set) var failed = false

  func load(_ realtime: RealtimeV2) async {
    do {
      let result = try await realtime.send(.getBilling())
      guard case let .getBilling(response) = result else { return }
      let ids = response.spaces.map(\.spaceID)
      let spaces = (try? await AppDatabase.shared.reader.read { db in try Space.fetchAll(db, ids: ids) }) ?? []
      spaceNames = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.name) })
      billing = response
      failed = false
      Self.cached = response
      Self.cachedSpaceNames = spaceNames
    } catch {
      log.error("Failed to load plan", error: error)
      if billing == nil { failed = true }
    }
  }
}
