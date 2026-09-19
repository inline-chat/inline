import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

private let log = Log.scoped("UserSettings")

struct NotificationSettingsValues: Equatable, Sendable {
  var mode: NotificationMode
  var silent: Bool
  var disableDmNotifications: Bool
  var shareTimeZone: Bool
  var appearInGlobalSearch: Bool
  var replacePastedLinksWithTitles: Bool
  var messageGestures: MessageGestureValues? = nil

  static let defaults = NotificationSettingsValues(
    mode: .all,
    silent: false,
    disableDmNotifications: false,
    shareTimeZone: true,
    appearInGlobalSearch: true,
    replacePastedLinksWithTitles: false
  )

  init(
    mode: NotificationMode,
    silent: Bool,
    disableDmNotifications: Bool,
    shareTimeZone: Bool = true,
    appearInGlobalSearch: Bool = true,
    replacePastedLinksWithTitles: Bool = false
  ) {
    self.mode = mode
    self.silent = silent
    self.disableDmNotifications = disableDmNotifications
    self.shareTimeZone = shareTimeZone
    self.appearInGlobalSearch = appearInGlobalSearch
    self.replacePastedLinksWithTitles = replacePastedLinksWithTitles
  }

  init(_ settings: NotificationSettingsManager) {
    mode = settings.mode
    silent = settings.silent
    disableDmNotifications = settings.disableDmNotifications
    shareTimeZone = true
    appearInGlobalSearch = true
    replacePastedLinksWithTitles = false
  }

  @MainActor
  init(
    _ notification: NotificationSettingsManager,
    _ privacy: PrivacySettingsManager,
    _ compose: ComposeSettingsManager,
    _ gestures: MessageGestureSettingsManager? = nil
  ) {
    mode = notification.mode
    silent = notification.silent
    disableDmNotifications = notification.disableDmNotifications
    shareTimeZone = privacy.shareTimeZone
    appearInGlobalSearch = privacy.appearInGlobalSearch
    replacePastedLinksWithTitles = compose.replacePastedLinksWithTitles
    messageGestures = gestures?.accountValues
  }

  init(_ settings: InlineProtocol.NotificationSettings) {
    let manager = NotificationSettingsManager(from: settings)
    self.init(manager)
  }

  init(_ settings: InlineProtocol.UserSettings) {
    let notification = settings.hasNotificationSettings
      ? NotificationSettingsManager(from: settings.notificationSettings)
      : NotificationSettingsManager()
    let privacy = settings.hasPrivacySettings
      ? PrivacySettingsManager(from: settings.privacySettings)
      : PrivacySettingsManager()
    let compose = settings.hasComposeSettings
      ? ComposeSettingsManager(from: settings.composeSettings)
      : ComposeSettingsManager()
    self.init(notification)
    shareTimeZone = privacy.shareTimeZone
    appearInGlobalSearch = privacy.appearInGlobalSearch
    replacePastedLinksWithTitles = compose.replacePastedLinksWithTitles
    messageGestures = settings.hasMessageGestureSettings ? MessageGestureValues(settings.messageGestureSettings) : nil
  }

  func apply(to settings: NotificationSettingsManager) {
    if settings.mode != mode {
      settings.mode = mode
    }
    if settings.silent != silent {
      settings.silent = silent
    }
    if settings.disableDmNotifications != disableDmNotifications {
      settings.disableDmNotifications = disableDmNotifications
    }
  }

  func apply(to settings: PrivacySettingsManager) {
    if settings.shareTimeZone != shareTimeZone {
      settings.shareTimeZone = shareTimeZone
    }
    if settings.appearInGlobalSearch != appearInGlobalSearch {
      settings.appearInGlobalSearch = appearInGlobalSearch
    }
  }

  func apply(to settings: ComposeSettingsManager) {
    if settings.replacePastedLinksWithTitles != replacePastedLinksWithTitles {
      settings.replacePastedLinksWithTitles = replacePastedLinksWithTitles
    }
  }

  func makeManager() -> NotificationSettingsManager {
    let manager = NotificationSettingsManager()
    apply(to: manager)
    return manager
  }
}

private enum UserSettingsRefreshError: Error {
  case invalidResponse
}

@MainActor
public class INUserSettings {
  public enum RefreshReason: String, Sendable {
    case initialization
    case authenticationChange
    case authenticatedScene
    case notificationPresentation
  }

  typealias CurrentUserIDProvider = @MainActor @Sendable () -> Int64?
  typealias FetchNotificationSettings = @Sendable () async throws -> NotificationSettingsValues?
  typealias SaveNotificationSettings = @Sendable (NotificationSettingsValues) async throws -> Void

  public static var current = INUserSettings()

  // MARK: - Public data

  public var notification = NotificationSettingsManager()
  public var privacy = PrivacySettingsManager()
  public var compose = ComposeSettingsManager()
  public let messageGestures: MessageGestureSettingsManager
  public var autoDownload = AutoDownloadSettingsManager()

  // MARK: - Private properties

  private var cancellables = Set<AnyCancellable>()
  private static let notificationSettingsKey = "notificationSettings"
  private static let notificationSettingsAccountKeyPrefix = "notificationSettings.account"
  private static let pendingNotificationAccountKeyPrefix = "notificationSettings.pending.account"
  private static let privacySettingsAccountKeyPrefix = "privacySettings.account"
  private static let pendingPrivacySettingsAccountKeyPrefix = "privacySettings.pending.account"
  private static let composeSettingsAccountKeyPrefix = "composeSettings.account"
  private static let pendingComposeSettingsAccountKeyPrefix = "composeSettings.pending.account"
  private static let legacyNotificationSettingsOwnerKey = "notificationSettings.legacyOwner.v1"
  private static let autoDownloadSettingsKey = "autoDownloadSettings"
  private let userDefaults: UserDefaults
  private let currentUserIDProvider: CurrentUserIDProvider
  private let fetchNotificationSettings: FetchNotificationSettings
  private let saveNotificationSettings: SaveNotificationSettings
  private var isApplyingServerUpdate = false
  private var notificationRevision: UInt64 = 0
  private var localNotificationRevision: UInt64 = 0
  private var activeUserID: Int64?
  private var pendingLocalRevision: UInt64?
  private var pendingLocalUserID: Int64?
  private var hasPendingGestureEdit = false
  private var pendingLocalValues: NotificationSettingsValues?
  private var pendingLocalCaptureTask: Task<Void, Never>?
  private var pendingServerUpdateTask: Task<Void, Never>?
  private var pendingServerUpdateTaskID: UUID?
  private var refreshRequest: RefreshRequest?

  private enum RefreshOutcome: Sendable {
    case success(NotificationSettingsValues?)
    case cancelled
    case failure
  }

  private struct RefreshRequest {
    let id: UUID
    let userID: Int64
    let notificationRevision: UInt64
    let localRevision: UInt64
    let task: Task<RefreshOutcome, Never>
  }

  // MARK: - Initialization

  public convenience init() {
    self.init(
      userDefaults: .shared,
      legacyGestureDefaults: .standard,
      currentUserID: { Auth.shared.getCurrentUserId() },
      fetchNotificationSettings: Self.fetchNotificationSettingsFromRealtime,
      saveNotificationSettings: Self.saveNotificationSettingsToRealtime
    )

    observeAuthenticationChanges()
    Task { @MainActor [weak self] in
      await self?.refresh(reason: .initialization)
    }
  }

  init(
    userDefaults: UserDefaults,
    legacyGestureDefaults: UserDefaults? = nil,
    currentUserID: @escaping CurrentUserIDProvider,
    fetchNotificationSettings: @escaping FetchNotificationSettings,
    saveNotificationSettings: @escaping SaveNotificationSettings
  ) {
    self.userDefaults = userDefaults
    messageGestures = MessageGestureSettingsManager(
      defaults: userDefaults,
      legacyDefaults: legacyGestureDefaults ?? userDefaults
    )
    currentUserIDProvider = currentUserID
    self.fetchNotificationSettings = fetchNotificationSettings
    self.saveNotificationSettings = saveNotificationSettings
    activeUserID = currentUserIDProvider()
    messageGestures.configure(for: activeUserID)

    // Load data from UserDefaults first
    loadFromUserDefaults()

    // Set up observation for changes
    setupObservation()
  }

  deinit {
    pendingLocalCaptureTask?.cancel()
    pendingServerUpdateTask?.cancel()
    refreshRequest?.task.cancel()
  }

  // MARK: - Refresh

  public func refresh(reason: RefreshReason) async {
    guard let userID = currentUserIDProvider() else {
      switchActiveUser(to: nil)
      return
    }

    switchActiveUser(to: userID)

    guard await flushPendingLocalChange(for: userID) else {
      log.debug("Skipping user settings refresh while a local change is pending")
      return
    }

    if let request = refreshRequest {
      if request.userID == userID {
        let outcome = await request.task.value
        finishRefresh(request, outcome: outcome, reason: reason)
        return
      }

      request.task.cancel()
      refreshRequest = nil
    }

    let requestID = UUID()
    let fetch = fetchNotificationSettings
    let task = Task { () -> RefreshOutcome in
      do {
        return .success(try await fetch())
      } catch is CancellationError {
        return .cancelled
      } catch {
        log.error("Failed to refresh user settings", error: error)
        return .failure
      }
    }
    let request = RefreshRequest(
      id: requestID,
      userID: userID,
      notificationRevision: notificationRevision,
      localRevision: localNotificationRevision,
      task: task
    )
    refreshRequest = request

    let outcome = await task.value
    finishRefresh(request, outcome: outcome, reason: reason)
  }

  // MARK: - Private methods

  private func setupObservation() {
    // Save to UserDefaults whenever notification settings change
    notification.objectWillChange
      .sink { [weak self] _ in
        self?.notificationSettingsWillChange()
      }
      .store(in: &cancellables)

    privacy.objectWillChange
      .sink { [weak self] _ in
        self?.notificationSettingsWillChange()
      }
      .store(in: &cancellables)

    compose.objectWillChange
      .sink { [weak self] _ in
        self?.notificationSettingsWillChange()
      }
      .store(in: &cancellables)

    messageGestures.$accountValues
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        if !self.isApplyingServerUpdate { self.hasPendingGestureEdit = true }
        self.notificationSettingsWillChange()
      }
      .store(in: &cancellables)

    autoDownload.objectWillChange
      .sink { [weak self] _ in
        self?.autoDownloadSettingsWillChange()
      }
      .store(in: &cancellables)
  }

  private func observeAuthenticationChanges() {
    Auth.shared.$currentUserId
      .removeDuplicates()
      .sink { [weak self] _ in
        Task { @MainActor in
          await self?.refresh(reason: .authenticationChange)
        }
      }
      .store(in: &cancellables)
  }

  private func notificationSettingsWillChange() {
    notificationRevision &+= 1
    guard !isApplyingServerUpdate else { return }

    localNotificationRevision &+= 1
    let revision = localNotificationRevision
    let userID = currentUserIDProvider()
    pendingLocalRevision = revision
    pendingLocalUserID = userID
    pendingLocalValues = nil

    pendingLocalCaptureTask?.cancel()
    pendingLocalCaptureTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled, revision == self.localNotificationRevision else { return }
      defer {
        if revision == self.localNotificationRevision { self.pendingLocalCaptureTask = nil }
      }
      guard let userID,
            self.activeUserID == userID,
            self.currentUserIDProvider() == userID
      else {
        if self.pendingLocalRevision == revision {
          self.clearPendingLocalChange()
        }
        return
      }

      let values = NotificationSettingsValues(self.notification, self.privacy, self.compose, self.messageGestures)
      self.pendingLocalValues = values
      self.savePendingNotificationSettingsToUserDefaults(values, for: userID)
      self.saveNotificationSettingsToUserDefaults(values, for: userID)
      self.debouncedSaveToRealtime(
        revision: revision,
        userID: userID,
        values: values
      )
    }
  }

  private func autoDownloadSettingsWillChange() {
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.saveAutoDownloadSettingsToUserDefaults()
    }
  }

  private func loadFromUserDefaults() {
    if let activeUserID {
      let values = restorePendingLocalChange(for: activeUserID)
        ?? loadNotificationSettingsFromUserDefaults(for: activeUserID)
        ?? .defaults
      values.apply(to: notification)
      values.apply(to: privacy)
      values.apply(to: compose)
      messageGestures.accountValues = values.messageGestures
    }

    loadAutoDownloadSettingsFromUserDefaults()
  }

  private func loadNotificationSettingsFromUserDefaults(for userID: Int64) -> NotificationSettingsValues? {
    let accountKey = notificationSettingsKey(for: userID)
    let notificationData: Data?

    if let accountData = userDefaults.data(forKey: accountKey) {
      notificationData = accountData
    } else if let legacyData = legacyNotificationSettingsData(for: userID) {
      userDefaults.set(legacyData, forKey: accountKey)
      notificationData = legacyData
    } else {
      notificationData = nil
    }

    guard let notificationData else {
      log.info("No cached notification settings found for current account")
      return nil
    }

    do {
      let cachedSettings = try JSONDecoder().decode(NotificationSettingsManager.self, from: notificationData)
      log.info("Loaded cached notification settings for current account")
      let privacy = loadPrivacySettingsFromUserDefaults(for: userID) ?? PrivacySettingsManager()
      let compose = loadComposeSettingsFromUserDefaults(for: userID) ?? ComposeSettingsManager()
      var values = NotificationSettingsValues(cachedSettings, privacy, compose)
      if let data = userDefaults.data(forKey: "messageGestures.account.\(userID)") {
        values.messageGestures = try? JSONDecoder().decode(MessageGestureValues.self, from: data)
      }
      return values
    } catch {
      log.error("Failed to decode cached notification settings: \(error)")
      return nil
    }
  }

  private func legacyNotificationSettingsData(for userID: Int64) -> Data? {
    let owner = userDefaults.string(forKey: Self.legacyNotificationSettingsOwnerKey)
    guard owner == nil || owner == String(userID) else { return nil }
    guard let data = userDefaults.data(forKey: Self.notificationSettingsKey) else { return nil }

    if owner == nil {
      userDefaults.set(String(userID), forKey: Self.legacyNotificationSettingsOwnerKey)
    }
    return data
  }

  private func notificationSettingsKey(for userID: Int64) -> String {
    "\(Self.notificationSettingsAccountKeyPrefix).\(userID)"
  }

  private func pendingNotificationSettingsKey(for userID: Int64) -> String {
    "\(Self.pendingNotificationAccountKeyPrefix).\(userID)"
  }

  private func privacySettingsKey(for userID: Int64) -> String {
    "\(Self.privacySettingsAccountKeyPrefix).\(userID)"
  }

  private func pendingPrivacySettingsKey(for userID: Int64) -> String {
    "\(Self.pendingPrivacySettingsAccountKeyPrefix).\(userID)"
  }

  private func composeSettingsKey(for userID: Int64) -> String {
    "\(Self.composeSettingsAccountKeyPrefix).\(userID)"
  }

  private func pendingComposeSettingsKey(for userID: Int64) -> String {
    "\(Self.pendingComposeSettingsAccountKeyPrefix).\(userID)"
  }

  private func loadPrivacySettingsFromUserDefaults(for userID: Int64) -> PrivacySettingsManager? {
    guard let data = userDefaults.data(forKey: privacySettingsKey(for: userID)) else { return nil }
    return try? JSONDecoder().decode(PrivacySettingsManager.self, from: data)
  }

  private func loadComposeSettingsFromUserDefaults(for userID: Int64) -> ComposeSettingsManager? {
    guard let data = userDefaults.data(forKey: composeSettingsKey(for: userID)) else { return nil }
    return try? JSONDecoder().decode(ComposeSettingsManager.self, from: data)
  }

  private func restorePendingLocalChange(for userID: Int64) -> NotificationSettingsValues? {
    let key = pendingNotificationSettingsKey(for: userID)
    guard let data = userDefaults.data(forKey: key) else { return nil }

    do {
      let manager = try JSONDecoder().decode(NotificationSettingsManager.self, from: data)
      let privacy: PrivacySettingsManager
      if let privacyData = userDefaults.data(forKey: pendingPrivacySettingsKey(for: userID)),
         let pendingPrivacy = try? JSONDecoder().decode(PrivacySettingsManager.self, from: privacyData) {
        privacy = pendingPrivacy
      } else {
        privacy = loadPrivacySettingsFromUserDefaults(for: userID) ?? PrivacySettingsManager()
      }
      let compose: ComposeSettingsManager
      if let composeData = userDefaults.data(forKey: pendingComposeSettingsKey(for: userID)),
         let pendingCompose = try? JSONDecoder().decode(ComposeSettingsManager.self, from: composeData) {
        compose = pendingCompose
      } else {
        compose = loadComposeSettingsFromUserDefaults(for: userID) ?? ComposeSettingsManager()
      }
      var values = NotificationSettingsValues(manager, privacy, compose)
      if let data = userDefaults.data(forKey: "messageGestures.pending.account.\(userID)") {
        values.messageGestures = try? JSONDecoder().decode(MessageGestureValues.self, from: data)
        hasPendingGestureEdit = values.messageGestures != nil
      } else if let data = userDefaults.data(forKey: "messageGestures.account.\(userID)") {
        values.messageGestures = try? JSONDecoder().decode(MessageGestureValues.self, from: data)
      }
      localNotificationRevision &+= 1
      pendingLocalRevision = localNotificationRevision
      pendingLocalUserID = userID
      pendingLocalValues = values
      log.info("Restored pending notification settings for current account")
      return values
    } catch {
      log.error("Failed to decode pending notification settings", error: error)
      userDefaults.removeObject(forKey: key)
      userDefaults.removeObject(forKey: pendingPrivacySettingsKey(for: userID))
      userDefaults.removeObject(forKey: pendingComposeSettingsKey(for: userID))
      userDefaults.removeObject(forKey: "messageGestures.pending.account.\(userID)")
      return nil
    }
  }

  private func loadAutoDownloadSettingsFromUserDefaults() {
    guard let data = userDefaults.data(forKey: Self.autoDownloadSettingsKey) else {
      log.info("No cached auto-download settings found")
      return
    }

    do {
      let cachedSettings = try JSONDecoder().decode(AutoDownloadSettingsManager.self, from: data)
      log.info("Loaded cached auto-download settings")

      autoDownload.mediaMaxMB = cachedSettings.mediaMaxMB
      autoDownload.fileMaxMB = cachedSettings.fileMaxMB
      autoDownload.voiceMaxMB = cachedSettings.voiceMaxMB
    } catch {
      log.error("Failed to decode cached auto-download settings: \(error)")
    }
  }

  private func saveNotificationSettingsToUserDefaults(
    _ values: NotificationSettingsValues,
    for userID: Int64
  ) {
    do {
      let notificationData = try JSONEncoder().encode(values.makeManager())
      userDefaults.set(notificationData, forKey: notificationSettingsKey(for: userID))
      let privacyData = try JSONEncoder().encode(values.makePrivacyManager())
      userDefaults.set(privacyData, forKey: privacySettingsKey(for: userID))
      let composeData = try JSONEncoder().encode(values.makeComposeManager())
      userDefaults.set(composeData, forKey: composeSettingsKey(for: userID))
      saveGestureValues(values.messageGestures, key: "messageGestures.account.\(userID)")
      log.trace("Saved notification settings to UserDefaults")
    } catch {
      log.error("Failed to encode notification settings: \(error)")
    }
  }

  private func savePendingNotificationSettingsToUserDefaults(
    _ values: NotificationSettingsValues,
    for userID: Int64
  ) {
    do {
      let data = try JSONEncoder().encode(values.makeManager())
      userDefaults.set(data, forKey: pendingNotificationSettingsKey(for: userID))
      let privacyData = try JSONEncoder().encode(values.makePrivacyManager())
      userDefaults.set(privacyData, forKey: pendingPrivacySettingsKey(for: userID))
      let composeData = try JSONEncoder().encode(values.makeComposeManager())
      userDefaults.set(composeData, forKey: pendingComposeSettingsKey(for: userID))
      saveGestureValues(hasPendingGestureEdit ? values.messageGestures : nil, key: "messageGestures.pending.account.\(userID)")
      log.trace("Saved pending notification settings to UserDefaults")
    } catch {
      log.error("Failed to encode pending notification settings", error: error)
    }
  }

  private func saveGestureValues(_ values: MessageGestureValues?, key: String) {
    if let values, let data = try? JSONEncoder().encode(values) {
      userDefaults.set(data, forKey: key)
    } else {
      userDefaults.removeObject(forKey: key)
    }
  }

  private func saveAutoDownloadSettingsToUserDefaults() {
    do {
      let data = try JSONEncoder().encode(autoDownload)
      userDefaults.set(data, forKey: Self.autoDownloadSettingsKey)
      log.trace("Saved auto-download settings to UserDefaults")
    } catch {
      log.error("Failed to encode auto-download settings: \(error)")
    }
  }

  private func debouncedSaveToRealtime(
    revision: UInt64,
    userID: Int64?,
    values: NotificationSettingsValues,
    delay: Bool = true
  ) {
    // Cancel any pending server update task
    pendingServerUpdateTask?.cancel()
    let taskID = UUID()
    pendingServerUpdateTaskID = taskID

    // Schedule a new debounced task
    pendingServerUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if delay {
          try await Task.sleep(for: .milliseconds(300))
        }

        guard !Task.isCancelled,
              self.pendingServerUpdateTaskID == taskID,
              self.localNotificationRevision == revision,
              self.currentUserIDProvider() == userID,
              userID != nil
        else { return }

        // Execute the actual save
        let didSave = await self.saveToRealtime(values)

        guard self.pendingServerUpdateTaskID == taskID else { return }
        self.pendingServerUpdateTask = nil
        self.pendingServerUpdateTaskID = nil
        if didSave, self.pendingLocalRevision == revision {
          self.clearPendingLocalChange(persistedFor: userID)
        }
      } catch is CancellationError {
        // Task was cancelled, which is expected behavior
        log.trace("Server update task was cancelled (superseded by newer change)")
      } catch {
        log.error("Error in debounced server update", error: error)
        guard self.pendingServerUpdateTaskID == taskID else { return }
        self.pendingServerUpdateTask = nil
        self.pendingServerUpdateTaskID = nil
      }
    }
  }

  private func saveToRealtime(_ values: NotificationSettingsValues) async -> Bool {
    log.trace("Saving user settings to Realtime")
    do {
      var outgoing = values
      // Only edits made while sync was enabled are published. An edit queued
      // before opting out still completes; subsequent local overrides stay local.
      if !hasPendingGestureEdit {
        outgoing.messageGestures = nil
      }
      try await saveNotificationSettings(outgoing)
      return true
    } catch is CancellationError {
      return false
    } catch {
      log.error("Failed to save user settings to server", error: error)
      return false
    }
  }

  private func flushPendingLocalChange(for userID: Int64) async -> Bool {
    guard pendingLocalRevision != nil else { return true }
    guard pendingLocalUserID == userID else {
      clearPendingLocalChange()
      return true
    }

    // @Published notifies before storing the new value. Await its actual
    // capture; yielding once does not guarantee that another task has run.
    while pendingLocalValues == nil, let captureTask = pendingLocalCaptureTask {
      await captureTask.value
    }

    if let pendingServerUpdateTask {
      await pendingServerUpdateTask.value
    }
    guard let revision = pendingLocalRevision else { return true }
    guard pendingLocalUserID == userID, let pendingLocalValues else { return false }

    debouncedSaveToRealtime(
      revision: revision,
      userID: userID,
      values: pendingLocalValues,
      delay: false
    )
    log.info("Retrying pending user settings save before refresh")

    if let pendingServerUpdateTask {
      await pendingServerUpdateTask.value
    }
    return pendingLocalRevision == nil
  }

  private func finishRefresh(
    _ request: RefreshRequest,
    outcome: RefreshOutcome,
    reason: RefreshReason
  ) {
    guard refreshRequest?.id == request.id else { return }
    refreshRequest = nil

    guard currentUserIDProvider() == request.userID,
          activeUserID == request.userID,
          notificationRevision == request.notificationRevision,
          localNotificationRevision == request.localRevision,
          pendingLocalRevision == nil
    else {
      log.debug("Discarded stale user settings refresh reason=\(reason.rawValue)")
      return
    }

    guard case let .success(values) = outcome else { return }
    applyServerNotificationSettings(values ?? .defaults, for: request.userID)
    log.info("User settings refreshed reason=\(reason.rawValue)")
  }

  private func applyServerNotificationSettings(
    _ values: NotificationSettingsValues,
    for userID: Int64
  ) {
    guard activeUserID == userID else { return }

    if NotificationSettingsValues(notification, privacy, compose, messageGestures) != values {
      isApplyingServerUpdate = true
      values.apply(to: notification)
      values.apply(to: privacy)
      values.apply(to: compose)
      messageGestures.accountValues = values.messageGestures
      isApplyingServerUpdate = false
    }
    saveNotificationSettingsToUserDefaults(values, for: userID)
  }

  private func switchActiveUser(to userID: Int64?) {
    guard activeUserID != userID else { return }

    refreshRequest?.task.cancel()
    refreshRequest = nil
    pendingServerUpdateTask?.cancel()
    pendingServerUpdateTask = nil
    pendingServerUpdateTaskID = nil
    clearPendingLocalChange()

    activeUserID = userID
    isApplyingServerUpdate = true
    messageGestures.configure(for: userID)
    isApplyingServerUpdate = false
    notificationRevision &+= 1
    localNotificationRevision &+= 1

    let values: NotificationSettingsValues
    if let userID {
      values = restorePendingLocalChange(for: userID)
        ?? loadNotificationSettingsFromUserDefaults(for: userID)
        ?? .defaults
    } else {
      values = .defaults
    }
    isApplyingServerUpdate = true
    values.apply(to: notification)
    values.apply(to: privacy)
    values.apply(to: compose)
    messageGestures.accountValues = values.messageGestures
    isApplyingServerUpdate = false
  }

  private func clearPendingLocalChange(persistedFor userID: Int64? = nil) {
    pendingLocalCaptureTask?.cancel()
    pendingLocalCaptureTask = nil
    if let userID {
      userDefaults.removeObject(forKey: pendingNotificationSettingsKey(for: userID))
      userDefaults.removeObject(forKey: pendingPrivacySettingsKey(for: userID))
      userDefaults.removeObject(forKey: pendingComposeSettingsKey(for: userID))
      userDefaults.removeObject(forKey: "messageGestures.pending.account.\(userID)")
    }
    pendingLocalRevision = nil
    pendingLocalUserID = nil
    pendingLocalValues = nil
    hasPendingGestureEdit = false
  }

  private static func fetchNotificationSettingsFromRealtime() async throws -> NotificationSettingsValues? {
    let response = try await Api.realtime.send(.getUserSettings())
    guard case let .getUserSettings(result) = response else {
      throw UserSettingsRefreshError.invalidResponse
    }

    return NotificationSettingsValues(result.userSettings)
  }

  private static func saveNotificationSettingsToRealtime(_ values: NotificationSettingsValues) async throws {
    _ = try await Api.realtime.send(.updateUserSettings(
      notificationSettings: values.makeManager(),
      privacySettings: values.makePrivacyManager(),
      composeSettings: values.makeComposeManager(),
      messageGestureSettings: values.messageGestures
    ))
  }

  public func updateFromServer(_ settings: InlineProtocol.UserSettings) {
    guard let receivingUserID = currentUserIDProvider() else { return }
    updateFromServer(settings, receivingUserID: receivingUserID)
  }

  func updateFromServer(_ settings: InlineProtocol.UserSettings, receivingUserID: Int64) {
    guard settings.hasNotificationSettings || settings.hasPrivacySettings || settings.hasComposeSettings || settings.hasMessageGestureSettings else { return }
    guard currentUserIDProvider() == receivingUserID else {
      log.debug("Ignored a user settings update received for a previous account")
      return
    }
    switchActiveUser(to: receivingUserID)
    guard pendingLocalRevision == nil else {
      // A notification/privacy/compose save does not own the gesture settings.
      // Keep remote gestures (including the value used when rejoining sync)
      // current without overwriting a pending gesture edit or a local override.
      if !hasPendingGestureEdit, settings.hasMessageGestureSettings {
        let gestures = MessageGestureValues(settings.messageGestureSettings)
        isApplyingServerUpdate = true
        messageGestures.accountValues = gestures
        isApplyingServerUpdate = false
        pendingLocalValues?.messageGestures = gestures
        saveGestureValues(gestures, key: "messageGestures.account.\(receivingUserID)")
      }
      log.debug("Ignored a live user settings update while a local change is pending")
      return
    }
    applyServerNotificationSettings(
      NotificationSettingsValues(settings),
      for: receivingUserID
    )
  }
}

private extension NotificationSettingsValues {
  func makePrivacyManager() -> PrivacySettingsManager {
    PrivacySettingsManager(
      shareTimeZone: shareTimeZone,
      appearInGlobalSearch: appearInGlobalSearch
    )
  }

  func makeComposeManager() -> ComposeSettingsManager {
    ComposeSettingsManager(replacePastedLinksWithTitles: replacePastedLinksWithTitles)
  }
}
