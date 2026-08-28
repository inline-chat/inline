import Auth
import Foundation
import InlineKit
import InlineSearch
import Logger

actor QuickSearchUsageStore {
  static let shared = QuickSearchUsageStore()

  private let log = Log.scoped("QuickSearchUsageStore")
  private let suppliedFileURL: URL?
  private let currentUserID: @Sendable () -> Int64?

  private var history = InlineSearchUsageHistory()
  private var didLoad = false
  private var saveTask: Task<Void, Never>?

  init(
    fileURL: URL? = nil,
    currentUserID: @escaping @Sendable () -> Int64? = { Auth.shared.handle.userId() }
  ) {
    suppliedFileURL = fileURL
    self.currentUserID = currentUserID
  }

  func rankingSignals(for query: String, now: Date = Date()) -> [Peer: InlineSearchUsageSignal] {
    loadIfNeeded()
    guard let accountKey = currentAccountKey else { return [:] }
    return history.rankingSignals(for: query, accountID: accountKey, now: now)
  }

  func recordSwitch(to peer: Peer, now: Date = Date()) {
    loadIfNeeded()
    guard let accountKey = currentAccountKey else { return }

    history.recordSwitch(to: peer, accountID: accountKey, now: now)
    scheduleSave()
  }

  func recordSelection(of peer: Peer, query: String, now: Date = Date()) {
    loadIfNeeded()
    guard let accountKey = currentAccountKey else { return }
    history.recordSelection(of: peer, query: query, accountID: accountKey, now: now)
    scheduleSave()
  }

  func clearCurrentAccount() {
    guard let userID = currentUserID() else { return }
    clear(accountID: userID)
  }

  func clear(accountID: Int64) {
    loadIfNeeded()
    let accountKey = String(accountID)
    guard history.clear(accountID: accountKey) else { return }
    scheduleSave()
  }

  private var currentAccountKey: String? {
    currentUserID().map(String.init)
  }

  private var fileURL: URL {
    suppliedFileURL ?? FileHelpers.getApplicationStateFileURL(named: "quick_search_usage_v2.json")
  }

  private func loadIfNeeded() {
    guard didLoad == false else { return }
    didLoad = true

    do {
      let data = try Data(contentsOf: fileURL)
      history = try JSONDecoder().decode(InlineSearchUsageHistory.self, from: data)
    } catch {
      let nsError = error as NSError
      if nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.fileReadNoSuchFile.rawValue {
        log.error("Failed to load quick-search usage state", error: error)
      }
      history = InlineSearchUsageHistory()
    }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard Task.isCancelled == false else { return }
      await self?.persist()
    }
  }

  private func persist() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(history).write(to: fileURL, options: .atomic)
    } catch {
      log.error("Failed to save quick-search usage state", error: error)
    }
  }

}
