import CryptoKit
import Foundation
import InlineNotificationFence
import Testing

@Suite("Notification delivery health")
struct NotificationDeliveryHealthTests {
  @Test("key IDs are stable per key and distinct across keys")
  func keyIDs() {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let id = PushContentKeyStore.keyID(for: key.publicKey)
    #expect(id.hasPrefix(PushContentKeyStore.keyIDPrefix))
    #expect(id.count == PushContentKeyStore.keyIDPrefix.count + 16)
    #expect(id == PushContentKeyStore.keyID(for: key.publicKey))
    #expect(id != PushContentKeyStore.keyID(for: Curve25519.KeyAgreement.PrivateKey().publicKey))
  }

  @Test("placeholder reasons accept only the server vocabulary")
  func placeholderReasons() {
    #expect(NotificationDeliveryHealth.placeholderReason(in: ["placeholderReason": "no_device_key"]) == "no_device_key")
    #expect(NotificationDeliveryHealth.placeholderReason(in: ["placeholderReason": "too_large"]) == "too_large")
    #expect(NotificationDeliveryHealth.placeholderReason(in: ["placeholderReason": "Ada says hi"]) == "unknown")
    #expect(NotificationDeliveryHealth.placeholderReason(in: [:]) == "unknown")
  }
}
