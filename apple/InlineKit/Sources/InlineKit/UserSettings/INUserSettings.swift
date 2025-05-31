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

  // MARK: - Private properties

  private var cancellables = Set<AnyCancellable>()
  private static let notificationSettingsKey = "notificationSettings"
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
        let wasTriggeredBecauseOfServerUpdate = self?.isApplyingServerUpdate == true
        Task { @MainActor in
          // sleep a bit to use fresh values
          self?.saveToUserDefaults()
          // Only sync to server if this is not a server update
          if !wasTriggeredBecauseOfServerUpdate {
            self?.debouncedSaveToRealtime()
          }
        }
      }
      .store(in: &cancellables)
  }

  private func loadFromUserDefaults() {
    guard let data = UserDefaults.shared.data(forKey: Self.notificationSettingsKey) else {
      log.debug("No cached notification settings found")
      return
    }

    do {
      let cachedSettings = try JSONDecoder().decode(NotificationSettingsManager.self, from: data)
      log.debug("Loaded cached notification settings")

      // Update current settings with cached values
      notification.mode = cachedSettings.mode
      notification.silent = cachedSettings.silent
      notification.requiresMention = cachedSettings.requiresMention
      notification.usesDefaultRules = cachedSettings.usesDefaultRules
      notification.customRules = cachedSettings.customRules
    } catch {
      log.error("Failed to decode cached notification settings: \(error)")
    }
  }

  private func saveToUserDefaults() {
    do {
      let data = try JSONEncoder().encode(notification)
      UserDefaults.shared.set(data, forKey: Self.notificationSettingsKey)
      log.debug("Saved notification settings to UserDefaults")
    } catch {
      log.error("Failed to encode notification settings: \(error)")
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
    log.debug("Saving notification settings to Realtime")
    let notificationProtocol = notification.toProtocol()
    do {
      _ = try await Realtime.shared
        .invoke(
          .updateUserSettings,
          input: .updateUserSettings((.with { $0.userSettings = .with {
            $0.notificationSettings = notificationProtocol
          } }))
        )
    } catch {
      log.error("Failed to save notification settings to server", error: error)
    }
  }

  private func fetch() {
    // Load data from app groups data continaer
    Task.detached {
      log.debug("Loading user settings")
      let data = try await Realtime.shared.invoke(
        .getUserSettings,
        input: .getUserSettings(.with { _ in })
      )

      if case let .getUserSettings(result) = data {
        log.debug("User settings loaded: \(result)")

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
    log.debug("Updating from user settings")

    if data.userSettings.hasNotificationSettings {
      isApplyingServerUpdate = true
      notification.update(from: data.userSettings.notificationSettings)
      DispatchQueue.main.async {
        self.isApplyingServerUpdate = false
      }
      // Save updated settings to UserDefaults
      saveToUserDefaults()
    }
  }

  // Add a public method for server updates
  public func updateFromServer(_ settings: InlineProtocol.NotificationSettings) {
    isApplyingServerUpdate = true
    notification.update(from: settings)
    DispatchQueue.main.async {
      self.isApplyingServerUpdate = false
    }
    saveToUserDefaults()
  }
}
