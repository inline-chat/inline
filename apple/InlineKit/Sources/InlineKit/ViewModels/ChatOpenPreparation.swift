import Foundation
import InlineCompat

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
    /// When the read ended; a window counts as fresh for `freshness` from then.
    var finishedAt: ContinuousClock.Instant?

    func isFresh(at now: ContinuousClock.Instant, for freshness: Duration) -> Bool {
      guard isFinished else { return true }
      return now - (finishedAt ?? startedAt) < freshness
    }
  }

  private let read: Read
  private let clock = ContinuousClock()
  private var entries: [Peer: Entry] = [:]
  private var waiters: [(peer: Peer, continuation: CheckedContinuation<InitialState?, Never>)] = []

  init(read: @escaping Read = { try await ChatOpenPreparation.readAtReadingPlace(peer: $0) }) {
    self.read = read
  }

  /// Reads the window at the chat's saved reading place, if any. A place the cache could not
  /// show is cleared, so the next open does not try it again.
  static func readAtReadingPlace(
    peer: Peer,
    store: ChatReadingPlaceStore = .shared,
    prepare: (Peer, ChatReadingPlace?) async throws -> InitialState = {
      try await MessagesProgressiveViewModel.prepareInitialState(peer: $0, savedPlace: $1)
    }
  ) async throws -> InitialState {
    let saved = store.place(for: peer)
    let state = try await prepare(peer, saved)
    // Only the place that was read is cleared; one saved since then is kept.
    if let saved, state.openAnchor != .saved(saved), store.place(for: peer) == saved {
      store.clear(for: peer)
    }
    return state
  }

  /// The chat's window, read unless a fresh one exists or is being read. Nil when the read failed;
  /// the list then reads its window itself.
  public func state(for peer: Peer) async -> InitialState? {
    startIfNeeded(peer)
    if let entry = entries[peer], entry.isFinished {
      return entry.state
    }
    return await withCheckedContinuation { waiters.append((peer, $0)) }
  }

  /// Starts reading a chat's window ahead of a likely open, without waiting for it: a chat-list row
  /// pressed is released about 100 ms later, and the read runs in that time instead of after it.
  public func prefetch(peer: Peer) {
    startIfNeeded(peer)
  }

  /// Starts a read unless a fresh one exists or one is running.
  private func startIfNeeded(_ peer: Peer) {
    let now = clock.now
    entries = entries.filter { $0.value.isFresh(at: now, for: Self.freshness) }
    guard entries[peer] == nil else { return }
    entries[peer] = Entry(startedAt: now)
    let read = read
    Task { [weak self] in
      let state = try? await read(peer)
      self?.finish(peer: peer, startedAt: now, state: state)
    }
  }

  /// A fresh window already read, so a view can be built from it in its first frame.
  public func readyState(for peer: Peer) -> InitialState? {
    guard let entry = entries[peer], entry.isFinished, entry.isFresh(at: clock.now, for: Self.freshness) else { return nil }
    return entry.state
  }

  /// A press that did not open its chat (it became a scroll or a context menu) drops what it read, so a
  /// later open within the freshness window does not show a window read before, say, Mark as Read. A read
  /// still running is left to an opener already waiting for it.
  public func discard(peer: Peer) {
    guard let entry = entries[peer] else { return }
    if entry.isFinished || !waiters.contains(where: { $0.peer == peer }) {
      entries[peer] = nil
    }
  }

  /// A read for this chat is running, so a view opening it waits for that rather than reading again.
  public func isPreparing(peer: Peer) -> Bool {
    entries[peer]?.isFinished == false
  }

  private func finish(peer: Peer, startedAt: ContinuousClock.Instant, state: InitialState?) {
    guard entries[peer]?.startedAt == startedAt else { return }
    entries[peer]?.isFinished = true
    entries[peer]?.finishedAt = clock.now
    entries[peer]?.state = state
    let finished = waiters.filter { $0.peer == peer }
    waiters.removeAll { $0.peer == peer }
    for waiter in finished {
      waiter.continuation.resume(returning: state)
    }
  }
}
