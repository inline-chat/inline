import Auth
import Combine
import InlineCompat
import Logger
import Observation
import SwiftUI

public struct ComposeActionInfo {
  public var userId: Int64
  public var action: ApiComposeAction
  var expiresAt: Date
}

public struct ComposeActionPresentation: Equatable, Sendable {
  public let action: ApiComposeAction
  public let text: String

  public init(action: ApiComposeAction, text: String) {
    self.action = action
    self.text = text
  }
}

@MainActor
public final class ComposeActionActivityState: CompatObservable {
  public let observationRegistrar = CompatObservationRegistrar()
  public let peer: Peer
  @Tracked public fileprivate(set) var presentation: ComposeActionPresentation? = nil

  fileprivate init(peer: Peer, presentation: ComposeActionPresentation?) {
    self.peer = peer
    self.presentation = presentation
  }
}

@available(iOS 17.0, macOS 14.0, *)
extension ComposeActionActivityState: Observable {}

private final class WeakComposeActionActivityState {
  weak var value: ComposeActionActivityState?

  init(_ value: ComposeActionActivityState) {
    self.value = value
  }
}

@MainActor
public class ComposeActions: ObservableObject {
  public static let shared = ComposeActions()

  // New structure: [Peer: [UserId: ComposeActionInfo]]
  @Published public var actions: [Peer: [Int64: ComposeActionInfo]] = [:]

  private var cancelTasks: [Peer: [Int64: Task<Void, Never>]] = [:]
  private var activityStates: [Peer: WeakComposeActionActivityState] = [:]
  private var activityStateLookupCount = 0
  private var log = Log.scoped("ComposeActions", enableTracing: false)
  private var lastTypingSent: [Peer: Date] = [:]

  // Sender side. Kept apart from the received-action timers above so another
  // user's update can never cancel or orphan our refresh loop.
  private let sendAction: @MainActor (Peer, ApiComposeAction?) async throws -> Void
  private let refreshInterval: Duration
  private var outgoingActivities: [OutgoingComposeActivity.ID: OutgoingActivityRecord] = [:]
  private var outgoingLoops: [Peer: OutgoingLoop] = [:]
  /// The last finished loop per peer, so a new loop's first send waits for its stop.
  private var outgoingTails: [Peer: Task<Void, Never>] = [:]

  public init() {
    sendAction = { peer, action in try await Self.sendComposeAction(for: peer, action: action) }
    refreshInterval = .seconds(3)
  }

  init(
    refreshInterval: Duration,
    sendAction: @escaping @MainActor (Peer, ApiComposeAction?) async throws -> Void
  ) {
    self.sendAction = sendAction
    self.refreshInterval = refreshInterval
  }

  // MARK: - New Group-Aware Methods

  /// Get all compose actions for a peer
  public func getComposeActions(for peer: Peer) -> [Int64: ComposeActionInfo] {
    actions[peer] ?? [:]
  }

  /// Get active typing users for a peer
  public func getTypingUsers(for peer: Peer) -> [Int64] {
    let currentActions = getComposeActions(for: peer)
    return currentActions.compactMap { userId, actionInfo in
      actionInfo.action == .typing ? userId : nil
    }
  }

  /// Add compose action for a specific user in a peer
  public func addComposeAction(for peer: Peer, action: ApiComposeAction, userId: Int64) {
    log.trace("action \(action) added for user \(userId) in \(peer)")

    // Cancel existing task for this user in this peer
    cancelTasks[peer]?[userId]?.cancel()
    if cancelTasks[peer] == nil {
      cancelTasks[peer] = [:]
    }

    // Initialize actions for peer if needed
    if actions[peer] == nil {
      actions[peer] = [:]
    }

    actions[peer]![userId] = ComposeActionInfo(userId: userId, action: action, expiresAt: Date().addingTimeInterval(6))
    refreshActivityState(for: peer)

    // Expire after 6s if not updated
    cancelTasks[peer]![userId] = Task {
      self.log.trace("typing action expired for user \(userId) in \(peer)")
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.removeComposeAction(for: peer, userId: userId)
      }
    }
  }

  /// Remove compose action for a specific user in a peer
  public func removeComposeAction(for peer: Peer, userId: Int64) {
    log.trace("removed action for user \(userId) in \(peer)")
    actions[peer]?[userId] = nil

    // Clean up empty peer entries
    if actions[peer]?.isEmpty == true {
      actions[peer] = nil
    }
    refreshActivityState(for: peer)

    cancelTasks[peer]?[userId]?.cancel()
    cancelTasks[peer]?[userId] = nil

    // Clean up empty peer entries in cancel tasks
    if cancelTasks[peer]?.isEmpty == true {
      cancelTasks[peer] = nil
    }
  }

  /// A user's new message ends what they were doing in that chat (Telegram does the
  /// same), so a lost stop never outlives the message it was for. Agent work is kept:
  /// an agent posts messages while it keeps working.
  public func noteMessageArrived(in peer: Peer, fromUserId userId: Int64) {
    guard let info = actions[peer]?[userId], info.action != .working else { return }
    removeComposeAction(for: peer, userId: userId)
  }

  /// Remove all compose actions for a peer
  public func removeAllComposeActions(for peer: Peer) {
    log.trace("removed all actions for \(peer)")

    // Cancel all tasks for this peer
    cancelTasks[peer]?.values.forEach { $0.cancel() }
    cancelTasks[peer] = nil

    // Remove all actions for this peer
    actions[peer] = nil
    refreshActivityState(for: peer)
  }

  // MARK: - Backwards Compatibility Methods

  /// Get the first compose action for a peer (backwards compatibility)
  public func getComposeAction(for peer: Peer) -> ComposeActionInfo? {
    actions[peer]?.values.first
  }

  /// Returns a narrowly observed, per-peer activity state for sidebar and list-row UI.
  /// The cache is weak so rows do not permanently retain state for every peer they display.
  public func activityState(for peer: Peer) -> ComposeActionActivityState {
    activityStateLookupCount &+= 1
    if activityStateLookupCount.isMultiple(of: 64) {
      activityStates = activityStates.filter { $0.value.value != nil }
    }

    if let state = activityStates[peer]?.value {
      return state
    }

    let state = ComposeActionActivityState(
      peer: peer,
      presentation: composeActionPresentation(for: peer)
    )
    activityStates[peer] = WeakComposeActionActivityState(state)
    return state
  }

  /// Remove compose action for peer (backwards compatibility - removes all)
  public func removeComposeAction(for peer: Peer) {
    removeAllComposeActions(for: peer)
  }

  private func composeActionPresentation(for peer: Peer) -> ComposeActionPresentation? {
    guard let action = getComposeAction(for: peer)?.action else { return nil }

    let textWithEllipsis: String
    if action == .typing {
      textWithEllipsis = getTypingDisplayText(for: peer, length: .short) ?? action.toHumanReadable()
    } else {
      textWithEllipsis = getActivityDisplayText(for: peer) ?? action.toHumanReadable()
    }

    return ComposeActionPresentation(
      action: action,
      text: Self.removingTrailingEllipsis(from: textWithEllipsis)
    )
  }

  private static func removingTrailingEllipsis(from text: String) -> String {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.last == "." || text.last == "…" {
      text.removeLast()
    }
    return text
  }

  private func refreshActivityState(for peer: Peer) {
    guard let state = activityStates[peer]?.value else {
      activityStates[peer] = nil
      return
    }

    state.presentation = composeActionPresentation(for: peer)
  }

  // MARK: - Synchronous Typing Display Text Methods

  /// Get display names for typing users synchronously
  public func getTypingUsersDisplayNames(for peer: Peer) -> [String] {
    let typingUserIds = getTypingUsers(for: peer)

    return typingUserIds.compactMap { userId in
      ObjectCache.shared.getUser(id: userId)?.user.displayName
    }
  }

  /// Get formatted typing text for display (synchronous)
  public func getTypingDisplayText(for peer: Peer, length: TypingDisplayLength = .full) -> String? {
    let displayNames = getTypingUsersDisplayNames(for: peer)

    // For DMs (user peers), use simpler copy since there's only one other user
    if peer.isPrivate {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          if length == .min {
            return "typing"
          } else {
            return "typing..."
          }
        default:
          // This shouldn't happen in a DM, but fallback to regular behavior
          if length == .min {
            return "typing"
          } else {
            return "typing..."
          }
      }
    }

    // For threads (group chats), show names as before
    if length == .full {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0]) is typing..."
        case 2:
          return "\(displayNames[0]) and \(displayNames[1]) are typing..."
        case 3:
          return "\(displayNames[0]), \(displayNames[1]) and \(displayNames[2]) are typing..."
        default:
          return "\(displayNames[0]), \(displayNames[1]) and \(displayNames.count - 2) others are typing..."
      }
    } else if length == .short {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0]) is typing..."
        case 2:
          return "\(displayNames[0]) and \(displayNames[1]) are typing..."
        default:
          return "\(displayNames[0]) and \(displayNames.count - 1) others are typing..."
      }
    } else {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0])"
        case 2:
          return "\(displayNames[0]) and \(displayNames[1])"
        default:
          return "\(displayNames[0]) and \(displayNames.count - 1) others"
      }
    }
  }

  /// The status line for a non-typing activity: "sending photo" in a DM, and
  /// "Mo is sending photo" where several people could be doing it (Telegram's copy).
  public func getActivityDisplayText(for peer: Peer) -> String? {
    guard let info = getComposeAction(for: peer), info.action != .typing else { return nil }
    let text = info.action.toHumanReadable()
    guard !peer.isPrivate,
          Self.namesActor(info.action),
          let name = ObjectCache.shared.getUser(id: info.userId)?.user.shortDisplayName,
          !name.isEmpty
    else { return text }
    return "\(name) is \(text)"
  }

  /// Activities a person does, so a group line names them. Agent "Working" stays as is.
  static func namesActor(_ action: ApiComposeAction) -> Bool {
    switch action {
      case .uploadingPhoto, .uploadingVideo, .uploadingDocument, .recordingVoice: true
      case .typing, .working: false
    }
  }

  /// Display length options for typing text
  public enum TypingDisplayLength {
    case full // "User is typing..."
    case short // "User is typing..."
    case min // "User"
  }

  // MARK: - Sending Methods

  // Sending side
  private static func sendComposeAction(for peerId: Peer, action: ApiComposeAction?) async throws {
    _ = try await Api.realtime.callRpcDirect(
      method: .sendComposeAction,
      input: .sendComposeAction(.with {
        $0.peerID = peerId.toInputPeer()
        $0.action = action?.toProtocolComposeAction() ?? .none
      }),
      timeout: .seconds(3)
    )
  }

  public func startedTyping(for peerId: Peer) async {
    // An upload or recording already speaks for this chat.
    if hasOutgoingActivity(in: peerId) {
      return
    }

    if let lastSent = lastTypingSent[peerId], lastSent.timeIntervalSinceNow > -3 {
      // Previous one still valid since it hasn't been 6s
      return
    }

    // Send typing action immediately
    do {
      lastTypingSent[peerId] = Date()
      log.trace("sending typing status for \(peerId)")
      try await sendAction(peerId, .typing)
    } catch {
      log.debug("Best-effort typing status was not sent: \(error)")
    }
  }

  public func stoppedTyping(for peerId: Peer) async {
    // Stopping typing must not clear an upload or recording status.
    if hasOutgoingActivity(in: peerId) {
      return
    }

    lastTypingSent[peerId] = nil

    // Send stop typing action immediately
    do {
      try await sendAction(peerId, nil)
    } catch {
      log.debug("Best-effort stop-typing status was not sent: \(error)")
    }
  }
}


// MARK: - Outgoing activities (uploads and recordings)

/// Handle for one upload or recording the current user is doing in a chat.
public struct OutgoingComposeActivity: Hashable, Sendable {
  public typealias ID = UUID
  public let id: ID
  public let peer: Peer
  public let action: ApiComposeAction
}

private struct OutgoingActivityRecord {
  let peer: Peer
  let action: ApiComposeAction
}

private struct OutgoingLoop {
  let id: UUID
  let wake: AsyncStream<Void>.Continuation
  let task: Task<Void, Never>
}

public extension ComposeActions {
  /// Starts broadcasting `action` in `peer` until the returned activity ends.
  ///
  /// Activities are reference counted per chat: several photos uploading at once
  /// share one status, and it clears only when the last one ends. One loop per
  /// chat owns every send, so a stop can't race ahead of a refresh. Like Telegram,
  /// there is no wall-clock limit: the status lives exactly as long as the work,
  /// and each upload step already has its own stall and processing limits.
  @discardableResult
  func beginActivity(_ action: ApiComposeAction, in peer: Peer) -> OutgoingComposeActivity {
    let activity = OutgoingComposeActivity(id: UUID(), peer: peer, action: action)
    outgoingActivities[activity.id] = OutgoingActivityRecord(peer: peer, action: action)

    if let loop = outgoingLoops[peer] {
      loop.wake.yield()
    } else {
      startOutgoingLoop(for: peer)
    }
    return activity
  }

  /// Ends an activity. Safe to call more than once.
  func endActivity(_ activity: OutgoingComposeActivity) {
    guard outgoingActivities.removeValue(forKey: activity.id) != nil else { return }
    outgoingLoops[activity.peer]?.wake.yield()
    finishOutgoingLoopIfIdle(for: activity.peer)
  }

  /// Runs `operation` with `action` shown in `peer`, ending it on every exit path.
  /// Prefer this over begin/end so the status can't outlive the work.
  nonisolated static func withActivity<T: Sendable>(
    _ action: ApiComposeAction,
    in peer: Peer,
    operation: () async throws -> T
  ) async throws -> T {
    let activity = await ComposeActions.shared.beginActivity(action, in: peer)
    do {
      let result = try await operation()
      await ComposeActions.shared.endActivity(activity)
      return result
    } catch {
      await ComposeActions.shared.endActivity(activity)
      throw error
    }
  }

  /// The action currently broadcast for `peer`, if any.
  func outgoingAction(in peer: Peer) -> ApiComposeAction? {
    outgoingActivities.values
      .filter { $0.peer == peer }
      .map(\.action)
      .max { Self.outgoingPriority($0) < Self.outgoingPriority($1) }
  }

  func hasOutgoingActivity(in peer: Peer) -> Bool {
    outgoingAction(in: peer) != nil
  }

  /// Keeps a voice-recording compose action alive until recording stops.
  func startVoiceRecording(for peerId: Peer) -> @Sendable () -> Void {
    let activity = beginActivity(.recordingVoice, in: peerId)
    return {
      Task { @MainActor in
        ComposeActions.shared.endActivity(activity)
      }
    }
  }
}

private extension ComposeActions {
  static func outgoingPriority(_ action: ApiComposeAction) -> Int {
    switch action {
      case .recordingVoice: 4
      case .uploadingVideo: 3
      case .uploadingPhoto: 2
      case .uploadingDocument: 1
      case .typing, .working: 0
    }
  }

  func startOutgoingLoop(for peer: Peer) {
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let previous = outgoingTails[peer]
    let interval = refreshInterval
    let loopID = UUID()

    let ticker = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        wake.yield()
      }
    }

    let task = Task { @MainActor [weak self] in
      // Never let our first send overtake the previous loop's stop.
      await previous?.value
      wake.yield()

      var lastSent: ApiComposeAction?
      for await _ in wakes {
        // A torn-down loop must not pick up a newer activity in the same chat;
        // that one belongs to the next loop, which runs after our stop.
        guard let self, self.outgoingLoops[peer]?.id == loopID,
              let action = self.outgoingAction(in: peer)
        else { break }
        do {
          try await self.sendAction(peer, action)
          lastSent = action
        } catch {
          // Keep refreshing; one timed-out send shouldn't drop the status mid-upload.
          self.log.debug("Best-effort \(action) status was not sent: \(error)")
        }
      }
      ticker.cancel()

      guard let self else { return }
      if lastSent != nil {
        do {
          try await self.sendAction(peer, nil)
        } catch {
          self.log.debug("Best-effort stop status was not sent: \(error)")
        }
      }
      self.lastTypingSent[peer] = nil
    }

    outgoingLoops[peer] = OutgoingLoop(id: loopID, wake: wake, task: task)
    outgoingTails[peer] = task
    Task { @MainActor [weak self] in
      await task.value
      if self?.outgoingTails[peer] == task {
        self?.outgoingTails[peer] = nil
      }
    }
  }

  func finishOutgoingLoopIfIdle(for peer: Peer) {
    guard outgoingActivities.values.contains(where: { $0.peer == peer }) == false,
          let loop = outgoingLoops.removeValue(forKey: peer)
    else { return }
    loop.wake.finish()
  }
}
