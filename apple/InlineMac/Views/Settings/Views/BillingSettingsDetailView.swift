import AppKit
import Auth
import GRDB
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

/// Plan & Billing: the viewer's plan, the spaces they administer, and any wallet credit.
/// Purchases and card changes happen on Stripe's pages in the browser.
struct BillingSettingsDetailView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var model = BillingSettingsModel()

  var body: some View {
    Form {
      if let billing = model.billing {
        personalSection(billing)
        if !billing.spaces.isEmpty {
          spacesSection(billing)
        }
        footerSection
      } else if model.failed {
        Section {
          SettingsEmptyRow(
            "Billing Unavailable",
            description: "Check your connection and try again.",
            systemImage: "creditcard"
          )
          Button("Try Again") { Task { await model.load(realtimeV2) } }
        }
      } else {
        Section {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading your plan…").foregroundStyle(.secondary)
          }
        }
      }
    }
    .settingsFormStyle()
    .task { await model.load(realtimeV2) }
    // Coming back from Stripe in the browser: pick up the new plan.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.load(realtimeV2) }
    }
    .alert(
      "Couldn't Open Billing",
      isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
      presenting: model.errorMessage
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
  }

  // MARK: Personal

  @ViewBuilder
  private func personalSection(_ billing: GetBillingResult) -> some View {
    let me = billing.me
    let offers = billing.plans.filter { !$0.forSpace }
    Section {
      if me.isPro, me.hasSubscription {
        planRow(me.subscription, isPro: true, spaceID: nil)
          .settingsSearchAnchor(.plan)
      } else {
        SettingsRowLabel(
          "Free",
          description: "Upgrade for more bots, larger files, more storage, and AI features like translation and cloud transcription."
        )
        .settingsSearchAnchor(.plan)
        ForEach(offers, id: \.code) { offer in
          offerRow(offer, spaceID: nil)
        }
      }
      if me.hasWallet {
        walletRow(me.wallet)
      }
    } header: {
      Text("Your Plan")
    }
  }

  // MARK: Spaces

  @ViewBuilder
  private func spacesSection(_ billing: GetBillingResult) -> some View {
    let offers = billing.plans.filter(\.forSpace)
    Section {
      ForEach(billing.spaces, id: \.spaceID) { account in
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text(model.spaceNames[account.spaceID] ?? "Space")
              .font(.body.weight(.medium))
            Spacer()
            spaceAction(account, offers: offers)
          }
          Text(spaceStatus(account))
            .font(.callout)
            .foregroundStyle(.secondary)
          if account.hasWallet {
            Text("Credit: \(BillingFormat.wallet(account.wallet))")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
    } header: {
      Text("Spaces You Manage")
    } footer: {
      Text("Team plans are billed per member and follow your member count. Members don't get personal Pro.")
    }
  }

  @ViewBuilder
  private func spaceAction(_ account: BillingAccount, offers: [BillingPlanOffer]) -> some View {
    if account.isPro, account.hasSubscription {
      if account.subscription.canManage {
        manageButton(spaceID: account.spaceID)
      }
    } else if !offers.isEmpty {
      Menu("Upgrade") {
        ForEach(offers, id: \.code) { offer in
          Button("\(BillingFormat.planTitle(offer.plan, interval: offer.interval)): \(BillingFormat.price(offer))") {
            Task { await model.checkout(offer.code, spaceID: account.spaceID, realtimeV2) }
          }
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(model.busy)
    }
  }

  private func spaceStatus(_ account: BillingAccount) -> String {
    guard account.isPro, account.hasSubscription else { return "Free" }
    let sub = account.subscription
    return "\(BillingFormat.planTitle(sub.plan, interval: sub.interval)) · \(BillingFormat.status(sub))"
  }

  // MARK: Rows

  private func planRow(_ sub: BillingSubscription, isPro: Bool, spaceID: Int64?) -> some View {
    HStack(alignment: .center) {
      SettingsRowLabel(
        LocalizedStringResource(stringLiteral: BillingFormat.planTitle(sub.plan, interval: sub.interval)),
        dynamicDescription: BillingFormat.status(sub)
      )
      Spacer()
      if sub.canManage {
        manageButton(spaceID: spaceID)
      }
    }
  }

  private func offerRow(_ offer: BillingPlanOffer, spaceID: Int64?) -> some View {
    HStack(alignment: .center) {
      SettingsRowLabel(
        LocalizedStringResource(stringLiteral: BillingFormat.planTitle(offer.plan, interval: offer.interval)),
        dynamicDescription: BillingFormat.offerDescription(offer)
      )
      Spacer()
      Button("Upgrade") {
        Task { await model.checkout(offer.code, spaceID: spaceID, realtimeV2) }
      }
      .disabled(model.busy)
    }
  }

  private func walletRow(_ wallet: BillingWallet) -> some View {
    SettingsRowLabel("Credit", dynamicDescription: BillingFormat.wallet(wallet))
  }

  private func manageButton(spaceID: Int64?) -> some View {
    Button("Manage…") {
      Task { await model.manage(spaceID: spaceID, realtimeV2) }
    }
    .disabled(model.busy)
  }

  private var footerSection: some View {
    Section {
      Text("Payments are handled by Stripe and Link. Enterprise plans for larger teams start at $30 per member a month; message the Inline team to set one up.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Model

@MainActor
@Observable
final class BillingSettingsModel {
  /// Last result for this run, so reopening the pane draws its plan on the first frame.
  /// Last result for this run and the account it belongs to, so reopening the pane draws on the
  /// first frame without ever showing another account's plan after a switch.
  private static var cached: (userID: Int64, billing: GetBillingResult, spaceNames: [Int64: String])?
  private static var cachedForCurrentUser: (billing: GetBillingResult, spaceNames: [Int64: String])? {
    guard let cached, cached.userID == Auth.shared.getCurrentUserId() else { return nil }
    return (cached.billing, cached.spaceNames)
  }

  private let log = Log.scoped("BillingSettings")
  private(set) var billing: GetBillingResult? = BillingSettingsModel.cachedForCurrentUser?.billing
  private(set) var spaceNames: [Int64: String] = BillingSettingsModel.cachedForCurrentUser?.spaceNames ?? [:]
  private(set) var failed = false
  private(set) var busy = false
  var errorMessage: String?

  func load(_ realtime: RealtimeV2) async {
    do {
      let result = try await realtime.send(.getBilling())
      guard case let .getBilling(response) = result else { throw BillingSettingsError.invalidResponse }
      let ids = response.spaces.map(\.spaceID)
      let names = (try? await AppDatabase.shared.reader.read { db in
        try Space.fetchAll(db, ids: ids)
      }) ?? []
      spaceNames = Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.name) })
      billing = response
      failed = false
      if let userID = Auth.shared.getCurrentUserId() {
        Self.cached = (userID, response, spaceNames)
      }
    } catch {
      log.error("Failed to load billing", error: error)
      if billing == nil { failed = true }
    }
  }

  func checkout(_ plan: String, spaceID: Int64?, _ realtime: RealtimeV2) async {
    await openURL {
      let result = try await realtime.send(.createBillingCheckout(plan: plan, spaceID: spaceID))
      guard case let .createBillingCheckout(response) = result else { throw BillingSettingsError.invalidResponse }
      return response.url
    }
  }

  func manage(spaceID: Int64?, _ realtime: RealtimeV2) async {
    await openURL {
      let result = try await realtime.send(.createBillingPortal(spaceID: spaceID))
      guard case let .createBillingPortal(response) = result else { throw BillingSettingsError.invalidResponse }
      return response.url
    }
  }

  private func openURL(_ fetch: () async throws -> String) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let string = try await fetch()
      guard let url = URL(string: string), url.scheme == "https" else { throw BillingSettingsError.invalidResponse }
      NSWorkspace.shared.open(url)
    } catch {
      log.error("Failed to open billing page", error: error)
      errorMessage = "Stripe couldn't be reached. Try again in a moment."
    }
  }
}

private enum BillingSettingsError: Error {
  case invalidResponse
}
