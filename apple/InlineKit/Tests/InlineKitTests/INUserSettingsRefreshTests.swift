import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("User settings refresh", .serialized)
@MainActor
struct INUserSettingsRefreshTests {
  @Test("global settings mutations share a durable account-local execution lane")
  func globalSettingsMutationsAreDurableAndOrdered() throws {
    let all = NotificationSettingsManager()
    all.mode = .all
    let none = NotificationSettingsManager()
    none.mode = .none

    let first = UpdateUserSettingsTransaction(notificationSettings: all)
    let second = UpdateUserSettingsTransaction(notificationSettings: none)

    #expect(first.executionKey == second.executionKey)
    let type = first.type
    guard case let .mutation(config) = type else {
      Issue.record("Expected a mutation transaction")
      return
    }
    #expect(config.retryAfterAck)
  }

  @Test("legacy notification transactions do not overwrite privacy")
  func legacyNotificationTransactionKeepsPrivacyAbsent() throws {
    let notification = NotificationSettingsManager()
    let legacyContext = try JSONDecoder().decode(
      UpdateUserSettingsTransaction.Context.self,
      from: JSONEncoder().encode(
        UpdateUserSettingsTransaction.Context(notificationSettings: notification)
      )
    )
    let transaction = UpdateUserSettingsTransaction(
      notificationSettings: legacyContext.notificationSettings,
      privacySettings: legacyContext.privacySettings
    )

    guard case let .updateUserSettings(input) = transaction.input(from: transaction.context) else {
      Issue.record("Expected an updateUserSettings input")
      return
    }
    #expect(input.userSettings.hasNotificationSettings)
    #expect(!input.userSettings.hasPrivacySettings)
  }

  @Test("coalesces concurrent refreshes for the same account")
  func coalescesConcurrentRefreshes() async throws {
    let harness = try makeHarness()
    defer { harness.removeUserDefaults() }

    let first = Task {
      await harness.settings.refresh(reason: .authenticatedScene)
    }
    let second = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }

    await harness.fetcher.waitForCalls(1)
    let callCount = await harness.fetcher.callCount
    #expect(callCount == 1)

    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: true,
      disableDmNotifications: true
    ))
    await first.value
    await second.value

    #expect(harness.settings.notification.mode == .none)
    #expect(harness.settings.notification.silent)
    #expect(harness.settings.notification.disableDmNotifications)
  }

  @Test("keeps a local edit made while refresh is in flight")
  func rejectsResponseAfterLocalEdit() async throws {
    let harness = try makeHarness()
    defer { harness.removeUserDefaults() }

    let refresh = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }
    await harness.fetcher.waitForCalls(1)

    harness.settings.notification.mode = .onlyMentions
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: false,
      disableDmNotifications: false
    ))
    await refresh.value

    #expect(harness.settings.notification.mode == .onlyMentions)

    // Let the injected no-op debounce complete before releasing the harness.
    try await Task.sleep(for: .milliseconds(350))
  }

  @Test("saves privacy edits through the shared user-settings lane")
  func savesPrivacyEdits() async throws {
    let harness = try makeHarness(controlledSaves: true)
    defer { harness.removeUserDefaults() }

    harness.settings.privacy.shareTimeZone = false
    harness.settings.privacy.appearInGlobalSearch = false

    await harness.saver.waitForCalls(1)
    let savedValues = await harness.saver.savedValues
    #expect(savedValues.last?.shareTimeZone == false)
    #expect(savedValues.last?.appearInGlobalSearch == false)
    await harness.saver.succeed()
  }

  @Test("rejects a response fetched for a previous account")
  func rejectsResponseAfterAccountSwitch() async throws {
    let harness = try makeHarness()
    defer { harness.removeUserDefaults() }

    let refresh = Task {
      await harness.settings.refresh(reason: .authenticatedScene)
    }
    await harness.fetcher.waitForCalls(1)

    harness.account.userID = 2
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: false,
      disableDmNotifications: false
    ))
    await refresh.value

    #expect(harness.settings.notification.mode == .all)
  }

  @Test("preserves cached settings when refresh fails")
  func preservesCacheAfterFailure() async throws {
    let harness = try makeHarness(cachedMode: .mentions)
    defer { harness.removeUserDefaults() }

    let refresh = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }
    await harness.fetcher.waitForCalls(1)
    await harness.fetcher.fail()
    await refresh.value

    #expect(harness.settings.notification.mode == .mentions)
  }

  @Test("rejects a deferred live update received for a previous account")
  func rejectsDeferredLiveUpdateAfterAccountSwitch() throws {
    let harness = try makeHarness()
    defer { harness.removeUserDefaults() }

    harness.account.userID = 2
    harness.settings.updateFromServer(
      .with { $0.notificationSettings = .with { $0.mode = .none } },
      receivingUserID: 1
    )

    #expect(harness.settings.notification.mode == .all)
  }

  @Test("isolates cached settings when the authenticated account changes")
  func isolatesCacheAcrossAccounts() async throws {
    let harness = try makeHarness()
    defer { harness.removeUserDefaults() }

    let firstRefresh = Task {
      await harness.settings.refresh(reason: .authenticatedScene)
    }
    await harness.fetcher.waitForCalls(1)
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: true,
      disableDmNotifications: false
    ))
    await firstRefresh.value
    #expect(harness.settings.notification.mode == .none)

    harness.account.userID = 2
    let secondRefresh = Task {
      await harness.settings.refresh(reason: .authenticatedScene)
    }
    await harness.fetcher.waitForCalls(2)
    #expect(harness.settings.notification.mode == .all)
    await harness.fetcher.fail()
    await secondRefresh.value
    #expect(harness.settings.notification.mode == .all)

    harness.account.userID = 1
    let restoredRefresh = Task {
      await harness.settings.refresh(reason: .authenticatedScene)
    }
    await harness.fetcher.waitForCalls(3)
    #expect(harness.settings.notification.mode == .none)
    await harness.fetcher.fail()
    await restoredRefresh.value
    #expect(harness.settings.notification.mode == .none)
  }

  @Test("retries a failed local save on the next refresh trigger")
  func retriesFailedLocalSave() async throws {
    let harness = try makeHarness(controlledSaves: true)
    defer { harness.removeUserDefaults() }

    harness.settings.notification.mode = .onlyMentions
    await harness.saver.waitForCalls(1)
    await harness.saver.fail()

    let refresh = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }
    await harness.saver.waitForCalls(2)
    let fetchCountWhilePending = await harness.fetcher.callCount
    #expect(fetchCountWhilePending == 0)
    await harness.saver.succeed()

    await harness.fetcher.waitForCalls(1)
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .onlyMentions,
      silent: false,
      disableDmNotifications: true
    ))
    await refresh.value

    #expect(harness.settings.notification.mode == .onlyMentions)
  }

  @Test("a refresh started with a local edit flushes the edited value")
  func immediateRefreshFlushesEditedValue() async throws {
    let harness = try makeHarness(controlledSaves: true)
    defer { harness.removeUserDefaults() }

    harness.settings.notification.mode = .none
    let refresh = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }

    await harness.saver.waitForCalls(1)
    let savedValues = await harness.saver.savedValues
    #expect(savedValues.first?.mode == NotificationMode.none)
    await harness.saver.succeed()
    await harness.fetcher.waitForCalls(1)
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: false,
      disableDmNotifications: false
    ))
    await refresh.value

    #expect(harness.settings.notification.mode == .none)
  }

  @Test("keeps a pending local edit ahead of a live server update")
  func keepsPendingLocalEditAheadOfLiveUpdate() async throws {
    let harness = try makeHarness(controlledSaves: true)
    defer { harness.removeUserDefaults() }

    harness.settings.notification.mode = .none
    await harness.saver.waitForCalls(1)

    harness.settings.updateFromServer(.with {
      $0.notificationSettings = .with { $0.mode = .all }
    })
    #expect(harness.settings.notification.mode == .none)

    let refresh = Task {
      await harness.settings.refresh(reason: .notificationPresentation)
    }
    await harness.saver.succeed()
    await harness.fetcher.waitForCalls(1)
    await harness.fetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: false,
      disableDmNotifications: false
    ))
    await refresh.value

    #expect(harness.settings.notification.mode == .none)
  }

  @Test("restores and retries an unsynced local edit after relaunch")
  func restoresPendingEditAfterRelaunch() async throws {
    let suiteName = "INUserSettingsRefreshTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let account = UserSettingsTestAccount(userID: 1)
    let firstFetcher = ControlledNotificationSettingsFetcher()
    let firstSaver = ControlledNotificationSettingsSaver(isControlled: true)
    let first = INUserSettings(
      userDefaults: userDefaults,
      currentUserID: { account.userID },
      fetchNotificationSettings: { try await firstFetcher.fetch() },
      saveNotificationSettings: { try await firstSaver.save($0) }
    )

    first.notification.mode = .none
    await firstSaver.waitForCalls(1)
    await firstSaver.fail()
    #expect(first.notification.mode == .none)

    let secondFetcher = ControlledNotificationSettingsFetcher()
    let secondSaver = ControlledNotificationSettingsSaver(isControlled: true)
    let second = INUserSettings(
      userDefaults: userDefaults,
      currentUserID: { account.userID },
      fetchNotificationSettings: { try await secondFetcher.fetch() },
      saveNotificationSettings: { try await secondSaver.save($0) }
    )
    #expect(second.notification.mode == .none)

    let secondRefresh = Task {
      await second.refresh(reason: .authenticatedScene)
    }
    await secondSaver.waitForCalls(1)
    let secondFetchCountWhilePending = await secondFetcher.callCount
    #expect(secondFetchCountWhilePending == 0)
    await secondSaver.succeed()
    await secondFetcher.waitForCalls(1)
    await secondFetcher.succeed(NotificationSettingsValues(
      mode: .none,
      silent: false,
      disableDmNotifications: false
    ))
    await secondRefresh.value

    let thirdFetcher = ControlledNotificationSettingsFetcher()
    let thirdSaver = ControlledNotificationSettingsSaver(isControlled: true)
    let third = INUserSettings(
      userDefaults: userDefaults,
      currentUserID: { account.userID },
      fetchNotificationSettings: { try await thirdFetcher.fetch() },
      saveNotificationSettings: { try await thirdSaver.save($0) }
    )
    #expect(third.notification.mode == .none)

    let thirdRefresh = Task {
      await third.refresh(reason: .authenticatedScene)
    }
    await thirdFetcher.waitForCalls(1)
    let thirdSaveCount = await thirdSaver.callCount
    #expect(thirdSaveCount == 0)
    await thirdFetcher.succeed(NotificationSettingsValues(
      mode: .all,
      silent: false,
      disableDmNotifications: false
    ))
    await thirdRefresh.value

    #expect(third.notification.mode == .all)
  }

  private func makeHarness(
    cachedMode: NotificationMode? = nil,
    controlledSaves: Bool = false
  ) throws -> UserSettingsRefreshHarness {
    let suiteName = "INUserSettingsRefreshTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))

    if let cachedMode {
      let cachedSettings = NotificationSettingsManager()
      cachedSettings.mode = cachedMode
      let data = try JSONEncoder().encode(cachedSettings)
      userDefaults.set(data, forKey: "notificationSettings")
    }

    let account = UserSettingsTestAccount(userID: 1)
    let fetcher = ControlledNotificationSettingsFetcher()
    let saver = ControlledNotificationSettingsSaver(isControlled: controlledSaves)
    let settings = INUserSettings(
      userDefaults: userDefaults,
      currentUserID: { account.userID },
      fetchNotificationSettings: { try await fetcher.fetch() },
      saveNotificationSettings: { try await saver.save($0) }
    )

    return UserSettingsRefreshHarness(
      settings: settings,
      account: account,
      fetcher: fetcher,
      saver: saver,
      userDefaults: userDefaults,
      suiteName: suiteName
    )
  }
}

@MainActor
private struct UserSettingsRefreshHarness {
  let settings: INUserSettings
  let account: UserSettingsTestAccount
  let fetcher: ControlledNotificationSettingsFetcher
  let saver: ControlledNotificationSettingsSaver
  let userDefaults: UserDefaults
  let suiteName: String

  func removeUserDefaults() {
    userDefaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private final class UserSettingsTestAccount {
  var userID: Int64?

  init(userID: Int64?) {
    self.userID = userID
  }
}

private actor ControlledNotificationSettingsFetcher {
  private typealias FetchContinuation = CheckedContinuation<NotificationSettingsValues?, any Error>
  private typealias CallWaiter = (count: Int, continuation: CheckedContinuation<Void, Never>)

  private var continuations: [FetchContinuation] = []
  private var callWaiters: [CallWaiter] = []
  private(set) var callCount = 0

  func fetch() async throws -> NotificationSettingsValues? {
    callCount += 1
    resumeReadyCallWaiters()
    return try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForCalls(_ count: Int) async {
    guard callCount < count else { return }
    await withCheckedContinuation { continuation in
      callWaiters.append((count, continuation))
    }
  }

  func succeed(_ values: NotificationSettingsValues?) {
    continuations.removeFirst().resume(returning: values)
  }

  func fail() {
    continuations.removeFirst().resume(throwing: UserSettingsTestError.fetchFailed)
  }

  private func resumeReadyCallWaiters() {
    let ready = callWaiters.filter { $0.count <= callCount }
    callWaiters.removeAll { $0.count <= callCount }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }
}

private actor ControlledNotificationSettingsSaver {
  private typealias SaveContinuation = CheckedContinuation<Void, any Error>
  private typealias CallWaiter = (count: Int, continuation: CheckedContinuation<Void, Never>)

  private let isControlled: Bool
  private var continuations: [SaveContinuation] = []
  private var callWaiters: [CallWaiter] = []
  private(set) var callCount = 0
  private(set) var savedValues: [NotificationSettingsValues] = []

  init(isControlled: Bool) {
    self.isControlled = isControlled
  }

  func save(_ values: NotificationSettingsValues) async throws {
    savedValues.append(values)
    callCount += 1
    resumeReadyCallWaiters()
    guard isControlled else { return }

    try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForCalls(_ count: Int) async {
    guard callCount < count else { return }
    await withCheckedContinuation { continuation in
      callWaiters.append((count, continuation))
    }
  }

  func succeed() {
    continuations.removeFirst().resume()
  }

  func fail() {
    continuations.removeFirst().resume(throwing: UserSettingsTestError.saveFailed)
  }

  private func resumeReadyCallWaiters() {
    let ready = callWaiters.filter { $0.count <= callCount }
    callWaiters.removeAll { $0.count <= callCount }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }
}

private enum UserSettingsTestError: Error {
  case fetchFailed
  case saveFailed
}
