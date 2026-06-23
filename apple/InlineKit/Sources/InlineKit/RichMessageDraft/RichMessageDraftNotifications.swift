import Foundation
import InlineProtocol

public enum RichMessageDraftNotifications {
  public static let update = Notification.Name("inline.richMessageDraft.update")
  public static let didChange = Notification.Name("inline.richMessageDraft.didChange")
  public static let updateKey = "update"
  public static let changeKey = "change"

  public static func post(_ update: InlineProtocol.UpdateRichMessageDraft) {
    let changes = RichMessageDraftStore.shared.apply(update)
    postOnMain(name: Self.update, userInfo: [Self.updateKey: update])
    post(changes: changes)
  }

  public static func update(from notification: Notification) -> InlineProtocol.UpdateRichMessageDraft? {
    notification.userInfo?[Self.updateKey] as? InlineProtocol.UpdateRichMessageDraft
  }

  public static func expireNow(now: Date = Date()) {
    post(changes: RichMessageDraftStore.shared.removeExpired(now: now))
  }

  public static func nextExpiryDate(now: Date = Date()) -> Date? {
    RichMessageDraftStore.shared.nextExpiryDate(now: now)
  }

  public static func change(from notification: Notification) -> RichMessageDraftChange? {
    notification.userInfo?[Self.changeKey] as? RichMessageDraftChange
  }

  private static func post(changes: [RichMessageDraftChange]) {
    for change in changes {
      postOnMain(name: Self.didChange, userInfo: [Self.changeKey: change])
    }
  }

  private static func postOnMain(name: Notification.Name, userInfo: [AnyHashable: Any]) {
    let payload = NotificationPostPayload(name: name, userInfo: userInfo)

    if Thread.isMainThread {
      payload.post()
      return
    }

    DispatchQueue.main.async {
      payload.post()
    }
  }
}

private struct NotificationPostPayload: @unchecked Sendable {
  let name: Notification.Name
  let userInfo: [AnyHashable: Any]

  func post() {
    NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
  }
}
