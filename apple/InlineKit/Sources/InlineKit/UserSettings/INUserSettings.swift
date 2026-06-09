import Combine
import Foundation
import InlineProtocol
import Logger

private let log = Log.scoped("UserSettings")

@MainActor
public class INUserSettings {
  public static var current = INUserSettings()

  // MARK: - Public data

  public var notification = NotificationSettingsManager()
  public var autoDownload = AutoDownloadSettingsManager()

  // MARK: - Private properties

  private var cancellables = Set<AnyCancellable>()
  private static let notificationSettingsKey = "notificationSettings"
  private static let autoDownloadSettingsKey = "autoDownloadSettings"
  private var isApplyingServerUpdate = false
  private var pendingServerUpdateTask: Task<Void, Never>?

  // MARK: - Initialization

  public init() {
    // Load data from UserDefaults first
    loadFromUserDefaults()

    // Set up observation for changes
    setupObservation()

    // Fetch from server
    fetch()
  }

  // MARK: - Private methods

  private func setupObservation() {
    // Save to UserDefaults whenever notification settings change
    notification.objectWillChange
      .sink { [weak self] _ in
        self?.settingsWillChange(syncToRealtime: true)
      }
      .store(in: &cancellables)

    autoDownload.objectWillChange
      .sink { [weak self] _ in
        self?.settingsWillChange(syncToRealtime: false)
      }
      .store(in: &cancellables)
  }

  private func settingsWillChange(syncToRealtime: Bool) {
    let wasTriggeredBecauseOfServerUpdate = isApplyingServerUpdate
    Task { @MainActor in
      // Save after the published value has updated.
      await Task.yield()
      self.saveToUserDefaults()
      // Only sync to server if this is not a server update
      if syncToRealtime && !wasTriggeredBecauseOfServerUpdate {
        self.debouncedSaveToRealtime()
      }
    }
  }

  private func loadFromUserDefaults() {
    guard let notificationData = UserDefaults.shared.data(forKey: Self.notificationSettingsKey) else {
      log.info("No cached notification settings found")
      loadAutoDownloadSettingsFromUserDefaults()
      return
    }

    do {
      let cachedSettings = try JSONDecoder().decode(NotificationSettingsManager.self, from: notificationData)
      log.info("Loaded cached notification settings")

      // Update current settings with cached values
      notification.mode = cachedSettings.mode
      notification.silent = cachedSettings.silent
      notification.disableDmNotifications = cachedSettings.disableDmNotifications
    } catch {
      log.error("Failed to decode cached notification settings: \(error)")
    }

    loadAutoDownloadSettingsFromUserDefaults()
  }

  private func loadAutoDownloadSettingsFromUserDefaults() {
    guard let data = UserDefaults.shared.data(forKey: Self.autoDownloadSettingsKey) else {
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

  private func saveToUserDefaults() {
    do {
      let notificationData = try JSONEncoder().encode(notification)
      UserDefaults.shared.set(notificationData, forKey: Self.notificationSettingsKey)

      let autoDownloadData = try JSONEncoder().encode(autoDownload)
      UserDefaults.shared.set(autoDownloadData, forKey: Self.autoDownloadSettingsKey)
      log.trace("Saved user settings to UserDefaults")
    } catch {
      log.error("Failed to encode user settings: \(error)")
    }
  }

  private func debouncedSaveToRealtime() {
    // Cancel any pending server update task
    pendingServerUpdateTask?.cancel()

    // Schedule a new debounced task
    pendingServerUpdateTask = Task { @MainActor in
      do {
        // Wait for debounce period
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // Check if task was cancelled
        try Task.checkCancellation()

        // Execute the actual save
        await saveToRealtime()

        // Clear the pending task reference
        pendingServerUpdateTask = nil
      } catch is CancellationError {
        // Task was cancelled, which is expected behavior
        log.trace("Server update task was cancelled (superseded by newer change)")
      } catch {
        log.error("Error in debounced server update", error: error)
        pendingServerUpdateTask = nil
      }
    }
  }

  private func saveToRealtime() async {
    log.trace("Saving user settings to Realtime")
    do {
      try await Api.realtime.send(.updateUserSettings(
        notificationSettings: notification
      ))
    } catch {
      log.error("Failed to save user settings to server", error: error)
    }
  }

  private func fetch() {
    // Load data from app groups data continaer
    Task.detached {
      log.info("Loading user settings")
      let data = try await Realtime.shared.invoke(
        .getUserSettings,
        input: .getUserSettings(.with { _ in })
      )

      if case let .getUserSettings(result) = data {
        log.info("User settings loaded")

        Task { @MainActor [weak self] in
          self?.update(from: result)
        }
      } else {
        log.error("Failed to load user settings: \(data.debugDescription)")
      }
    }
  }

  private func update(from data: InlineProtocol.GetUserSettingsResult) {
    // Save data to app groups data container
    log.trace("Updating from user settings")

    guard data.userSettings.hasNotificationSettings else { return }

    isApplyingServerUpdate = true
    notification.update(from: data.userSettings.notificationSettings)
    DispatchQueue.main.async {
      self.isApplyingServerUpdate = false
    }
    // Save updated settings to UserDefaults
    saveToUserDefaults()
  }

  // Add a public method for server updates
  public func updateFromServer(_ settings: InlineProtocol.UserSettings) {
    guard settings.hasNotificationSettings else { return }

    isApplyingServerUpdate = true
    notification.update(from: settings.notificationSettings)
    DispatchQueue.main.async {
      self.isApplyingServerUpdate = false
    }
    saveToUserDefaults()
  }
}
