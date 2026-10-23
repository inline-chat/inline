import Foundation

/// Reads a chat's first message window off the main actor, so its view is built complete in the
/// first frame. Navigation waits for the read before showing a chat, as Telegram waits for a chat
/// controller's `ready` before pushing it.
@MainActor
public final class ChatOpenPreparation {
  public typealias InitialState = MessagesProgressiveViewModel.InitialState
  typealias Read = @MainActor (Peer) async throws -> InitialState

  public static let shared = ChatOpenPreparation()

  /// A window read longer ago than this is read again rather than shown. A newer one would only
  /// be corrected by the view model's reconciliation after the first frame.
  static let freshness: Duration = .seconds(2)

  private struct Entry {
    let startedAt: ContinuousClock.Instant
    var isFinished = false
    var state: InitialState?
  }

  private let read: Read
  private let clock = ContinuousClock()
  private var entries: [Peer: Entry] = [:]
  private var waiters: [(peer: Peer, continuation: CheckedContinuation<InitialState?, Never>)] = []

  init(read: @escaping Read = { try await MessagesProgressiveViewModel.prepareInitialState(peer: $0) }) {
    self.read = read
  }

  /// The chat's window, read unless a fresh one exists or is being read. Nil when the read failed;
  /// the list then reads its window itself.
  public func state(for peer: Peer) async -> InitialState? {
    let now = clock.now
    entries = entries.filter { !$0.value.isFinished || now - $0.value.startedAt < Self.freshness }
    if let entry = entries[peer], entry.isFinished {
      return entry.state
    }
    if entries[peer] == nil {
      entries[peer] = Entry(startedAt: now)
      let read = read
      Task { [weak self] in
        let state = try? await read(peer)
        self?.finish(peer: peer, startedAt: now, state: state)
      }
    }
    return await withCheckedContinuation { waiters.append((peer, $0)) }
  }

  /// A fresh window already read, so a view can be built from it in its first frame.
  public func readyState(for peer: Peer) -> InitialState? {
    guard let entry = entries[peer], entry.isFinished, clock.now - entry.startedAt < Self.freshness else {
      return nil
    }
    return entry.state
  }

  /// A read for this chat is running, so a view opening it waits for that rather than reading again.
  public func isPreparing(peer: Peer) -> Bool {
    entries[peer]?.isFinished == false
  }

  private func finish(peer: Peer, startedAt: ContinuousClock.Instant, state: InitialState?) {
    guard entries[peer]?.startedAt == startedAt else { return }
    entries[peer]?.isFinished = true
    entries[peer]?.state = state
    let finished = waiters.filter { $0.peer == peer }
    waiters.removeAll { $0.peer == peer }
    for waiter in finished {
      waiter.continuation.resume(returning: state)
    }
  }
}
