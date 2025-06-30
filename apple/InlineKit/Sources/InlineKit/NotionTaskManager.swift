import Auth
import Foundation
import Logger

// MARK: - Error Types

/// Errors that can occur during Notion task creation
public enum NotionTaskError: Error, LocalizedError {
  case spaceSelectionRequired
  case integrationNotFound
  case apiError(String)

  public var errorDescription: String? {
    switch self {
      case .spaceSelectionRequired:
        "Space selection is required"
      case .integrationNotFound:
        "No Notion integration found"
      case let .apiError(message):
        message
    }
  }
}

// MARK: - Protocols

public protocol NotionTaskManagerDelegate: AnyObject, Sendable {
  func showErrorToast(_ message: String, systemImage: String)
  func showSuccessToast(_ message: String, systemImage: String, url: String)
  func showSpaceSelectionSheet(spaces: [NotionSpace], completion: @escaping @Sendable (Int64) -> Void)
  func showProgressStep(_ step: Int, message: String, systemImage: String)
  func updateProgressToast(message: String, systemImage: String)
}

public class NotionTaskManager: @unchecked Sendable {
  public static let shared = NotionTaskManager()

  private let accessQueue = DispatchQueue(label: "NotionTaskManager.access", attributes: .concurrent)
  private var _hasIntegrationAccess: Bool = false
  private let log = Log.scoped("NotionTaskManager")
  public weak var delegate: NotionTaskManagerDelegate?

  public init() {}

  // MARK: - Public Interface

  /// Checks if user has integration access for the given peer and space
  public func checkIntegrationAccess(peerId: Peer, spaceId: Int64) async {
    do {
      let integrations = try await ApiClient.shared.getIntegrations(
        userId: Auth.shared.getCurrentUserId() ?? 0,
        spaceId: peerId.isThread ? spaceId : nil
      )

      accessQueue.async(flags: .barrier) {
        self._hasIntegrationAccess = integrations.hasIntegrationAccess
      }
    } catch {
      log.error("Error checking integration access: \(error)")
      accessQueue.async(flags: .barrier) {
        self._hasIntegrationAccess = false
      }
    }
  }

  /// Gets the current integration access status
  public var hasAccess: Bool {
    accessQueue.sync {
      _hasIntegrationAccess
    }
  }

  /// Handles the Will Do action for a message
  public func handleWillDoAction(for message: Message, spaceId: Int64? = nil) async {
    // For thread chats, use the provided spaceId
    if message.peerId.isThread, let spaceId {
      await handleWillDoForSpace(message: message, spaceId: spaceId)
      return
    }

    // For DM chats, handle without storing preferences
    await handleWillDoForDM(message: message)
  }

  // MARK: - Private Implementation

  private func handleWillDoForSpace(message: Message, spaceId: Int64) async {
    do {
      // Check if user has access to integration
      let integrations = try await ApiClient.shared.getIntegrations(
        userId: Auth.shared.getCurrentUserId() ?? 0,
        spaceId: spaceId
      )

      guard integrations.hasNotionConnected else {
        delegate?.showErrorToast(
          "No Notion integration access for this space",
          systemImage: "exclamationmark.triangle"
        )
        return
      }

      await createNotionTask(spaceId: spaceId, message: message)
    } catch {
      log.error("Error creating notion task: \(error)")
      delegate?.showErrorToast(
        "Failed to create Notion task",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  private func handleWillDoForDM(message: Message) async {
    do {
      // Get all accessible integrations for DMs
      let integrations = try await ApiClient.shared.getIntegrations(
        userId: Auth.shared.getCurrentUserId() ?? 0,
        spaceId: nil
      )

      guard integrations.hasNotionConnected else {
        delegate?.showErrorToast(
          "No Notion integration found. Please connect your Notion account in one of your spaces.",
          systemImage: "exclamationmark.triangle"
        )
        return
      }

      guard let notionSpaces = integrations.notionSpaces, !notionSpaces.isEmpty else {
        delegate?.showErrorToast(
          "No accessible Notion integrations found",
          systemImage: "exclamationmark.triangle"
        )
        return
      }

      // Show space selection for DMs
      delegate?.showSpaceSelectionSheet(spaces: notionSpaces) { [weak self] selectedSpaceId in
        Task {
          await self?.createNotionTask(spaceId: selectedSpaceId, message: message)
        }
      }
    } catch {
      log.error("Error handling will do for DM: \(error)")
      delegate?.showErrorToast(
        "Failed to create Notion task",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  private func createNotionTask(
    spaceId: Int64,
    message: Message
  ) async {
    let progressTracker = NotionTaskProgressTracker(delegate: delegate)

    // Start progress tracking
    let progressTask = Task {
      await progressTracker.startProgress()
    }

    do {
      let result = try await ApiClient.shared.createNotionTask(
        spaceId: spaceId,
        messageId: message.messageId,
        chatId: message.chatId,
        peerId: message.peerId
      )

      // Stop progress tracking
      await progressTracker.completeProgress()
      progressTask.cancel()

      delegate?.showSuccessToast(
        "Done",
        systemImage: "checkmark.circle",
        url: result.url
      )
    } catch {
      // Stop progress tracking on error
      await progressTracker.failProgress()
      progressTask.cancel()

      log.error("Error creating notion task: \(error)")
      delegate?.showErrorToast(
        "Failed to create Notion task",
        systemImage: "exclamationmark.triangle"
      )
    }
  }
}

// MARK: - NotionTaskProgressTracker

public final class NotionTaskProgressTracker: @unchecked Sendable {
  private let progressSteps: [(text: String, icon: String, estimatedDuration: TimeInterval)] = [
    ("Processing", "cylinder.split.1x2", 3.0),
    ("Assigning users", "person.2.circle", 2.0),
    ("Generating issue", "brain.head.profile", 2.0),
    ("Creating Notion page", "notion-logo", 2.0),
  ]

  private let stateQueue = DispatchQueue(label: "NotionTaskProgressTracker.state", attributes: .concurrent)
  private var _currentStepIndex = 0
  private var _isCompleted = false
  private var _isFailed = false
  private weak var delegate: NotionTaskManagerDelegate?

  public init(delegate: NotionTaskManagerDelegate?) {
    self.delegate = delegate
  }

  public func startProgress() async {
    stateQueue.async(flags: .barrier) {
      self._currentStepIndex = 0
      self._isCompleted = false
      self._isFailed = false
    }

    for (index, step) in progressSteps.enumerated() {
      let shouldContinue = stateQueue.sync {
        !_isCompleted && !_isFailed
      }

      if !shouldContinue {
        return
      }

      stateQueue.async(flags: .barrier) {
        self._currentStepIndex = index
      }

      delegate?.showProgressStep(
        index + 1,
        message: step.text,
        systemImage: step.icon
      )

      try? await Task.sleep(nanoseconds: UInt64(step.estimatedDuration * 1_000_000_000))
    }
  }

  public func completeProgress() async {
    stateQueue.async(flags: .barrier) {
      self._isCompleted = true
    }
  }

  public func failProgress() async {
    stateQueue.async(flags: .barrier) {
      self._isFailed = true
    }
  }

  public func updateProgress(to stepText: String) async {
    let shouldUpdate = stateQueue.sync {
      !_isCompleted && !_isFailed
    }

    guard shouldUpdate else { return }

    if let stepIndex = progressSteps.firstIndex(where: { $0.text == stepText }) {
      stateQueue.async(flags: .barrier) {
        self._currentStepIndex = stepIndex
      }
      let step = progressSteps[stepIndex]

      delegate?.updateProgressToast(
        message: step.text,
        systemImage: step.icon
      )
    }
  }

  public func advanceToStep(_ stepNumber: Int, customMessage: String? = nil) async {
    guard stepNumber >= 1, stepNumber <= progressSteps.count else { return }

    let shouldUpdate = stateQueue.sync {
      !_isCompleted && !_isFailed
    }

    guard shouldUpdate else { return }

    let stepIndex = stepNumber - 1
    stateQueue.async(flags: .barrier) {
      self._currentStepIndex = stepIndex
    }
    let step = progressSteps[stepIndex]

    let message = customMessage ?? step.text

    delegate?.showProgressStep(
      stepNumber,
      message: message,
      systemImage: step.icon
    )
  }
}
