import AppKit

@MainActor
final class DockBadgeController {
  private var lastAppliedCount: Int = 0
  private var pendingIncreaseTask: Task<Void, Never>?
  private var increaseGeneration: UInt64 = 0

  func setUnreadDMCount(_ count: Int, debounceIncreases: Bool = true) {
    if !debounceIncreases {
      increaseGeneration &+= 1
      pendingIncreaseTask?.cancel()
      pendingIncreaseTask = nil
      applyNow(count)
      lastAppliedCount = count
      return
    }

    // Avoid badge "flicker" when an unread message arrives and is immediately marked read.
    // Apply decreases (especially to 0) immediately; debounce increases by 500ms.
    //
    // Note: cancelation of a Task is cooperative, so a "canceled" debounce task could still wake up
    // and attempt to apply a stale increase. We therefore also gate delayed applies behind an
    // incrementing generation token (`increaseGeneration`) and check cancellation after sleeping.
    if count <= lastAppliedCount {
      increaseGeneration &+= 1
      pendingIncreaseTask?.cancel()
      pendingIncreaseTask = nil
      applyNow(count)
      lastAppliedCount = count
      return
    }

    increaseGeneration &+= 1
    let generation = increaseGeneration

    pendingIncreaseTask?.cancel()
    pendingIncreaseTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 500_000_000)
        try Task.checkCancellation()
      } catch {
        return
      }

      guard generation == self.increaseGeneration else { return }
      applyNow(count)
      lastAppliedCount = count
    }
  }

  private func applyNow(_ count: Int) {
    let label: String? = if count <= 0 {
      nil
    } else if count > 99 {
      "99+"
    } else {
      String(count)
    }

    NSApplication.shared.dockTile.badgeLabel = label
  }
}
