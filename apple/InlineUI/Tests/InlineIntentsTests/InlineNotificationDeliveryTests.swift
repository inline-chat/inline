import Foundation
import Testing
import UserNotifications
@testable import InlineIntents

@Suite("Notification delivery lifetime")
struct InlineNotificationDeliveryTests {
  @Test func expiryBeforeEnrichmentDeliversOriginalSynchronously() {
    let original = UNMutableNotificationContent()
    original.body = "New message"
    var delivered: [String] = []
    let delivery = InlineNotificationDelivery(content: original) { delivered.append($0.body) }
    delivery.finish()
    #expect(delivered == ["New message"])
    #expect(!delivery.isPending)
  }

  @Test func expiryUsesImmutableDecryptedSnapshotAndIgnoresLateEnrichment() {
    let content = UNMutableNotificationContent()
    var delivered: [String] = []
    let delivery = InlineNotificationDelivery(content: content) { delivered.append($0.body) }
    content.body = "Decrypted message"
    #expect(delivery.updateFallback(content))
    content.body = "Late mutation"
    delivery.finish()
    #expect(!delivery.updateFallback(content))
    delivery.finish(with: content)
    #expect(delivered == ["Decrypted message"])
  }

  @Test func competingExpiryAndCompletionInvokeHandlerAndCancellationOnce() {
    let result = Counter()
    let delivery = InlineNotificationDelivery(content: UNMutableNotificationContent()) { _ in result.increment() }
    let cancelled = Counter()
    delivery.cancelOnFinish { cancelled.increment() }
    DispatchQueue.concurrentPerform(iterations: 100) { _ in delivery.finish() }
    #expect(result.value == 1)
    #expect(cancelled.value == 1)
    delivery.cancelOnFinish { cancelled.increment() }
    #expect(cancelled.value == 2)
  }

  @Test func fallbackAcceptanceAgreesWithDeliveryWhenExpiryRaces() {
    for _ in 0..<100 {
      let accepted = Counter()
      let delivered = Counter()
      let delivery = InlineNotificationDelivery(content: UNMutableNotificationContent()) {
        if $0.body == "photo" { delivered.increment() }
      }
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 {
          let enriched = UNMutableNotificationContent()
          enriched.body = "photo"
          if delivery.updateFallback(enriched) { accepted.increment() }
        } else {
          delivery.finish()
        }
      }
      #expect(accepted.value == delivered.value)
    }
  }

  @Test func completionIsReentrantAndRequestsAreIndependent() {
    let firstCount = Counter()
    let secondCount = Counter()
    let first = InlineNotificationDelivery(content: UNMutableNotificationContent()) { _ in firstCount.increment() }
    let second = InlineNotificationDelivery(content: UNMutableNotificationContent()) { _ in secondCount.increment() }
    first.cancelOnFinish { first.finish() }
    first.finish()
    #expect(second.isPending)
    second.finish()
    first.finish()
    #expect(firstCount.value == 1)
    #expect(secondCount.value == 1)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
