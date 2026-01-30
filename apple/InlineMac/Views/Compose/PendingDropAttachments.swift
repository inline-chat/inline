import Foundation
import InlineKit

final class PendingDropAttachments {
  static let shared = PendingDropAttachments()
  static let didUpdateNotification = Notification.Name("pendingDropAttachmentsUpdated")

  private var pendingByPeer: [Peer: [PasteboardAttachment]] = [:]

  func enqueue(peerId: Peer, attachments: [PasteboardAttachment]) {
    guard attachments.isEmpty == false else { return }
    pendingByPeer[peerId, default: []].append(contentsOf: attachments)
    NotificationCenter.default.post(
      name: Self.didUpdateNotification,
      object: nil,
      userInfo: ["peerId": peerId]
    )
  }

  func consume(peerId: Peer) -> [PasteboardAttachment] {
    pendingByPeer.removeValue(forKey: peerId) ?? []
  }

  func hasPending(peerId: Peer) -> Bool {
    pendingByPeer[peerId]?.isEmpty == false
  }
}
