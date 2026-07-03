import Foundation

struct SendMessageAnimationListRemainder {
  let items: Set<MessageListItem>
  let identities: Set<SendMessageAnimationIdentity>

  var isEmpty: Bool {
    items.isEmpty && identities.isEmpty
  }
}

struct SendMessageAnimationListTransaction {
  private var items: Set<MessageListItem> = []
  private var identities: Set<SendMessageAnimationIdentity> = []

  var hasPendingTargets: Bool {
    !items.isEmpty || !identities.isEmpty
  }

  mutating func insert(
    items newItems: Set<MessageListItem>,
    identities newIdentities: Set<SendMessageAnimationIdentity>
  ) {
    items.formUnion(newItems)
    identities.formUnion(newIdentities)
  }

  func contains(
    item: MessageListItem,
    identity: SendMessageAnimationIdentity
  ) -> Bool {
    items.contains(item) || identities.contains(identity)
  }

  mutating func remove(
    item: MessageListItem,
    identity: SendMessageAnimationIdentity?
  ) {
    items.remove(item)
    if let identity {
      identities.remove(identity)
    }
  }

  func remainder(
    for candidateItems: Set<MessageListItem>,
    identities candidateIdentities: Set<SendMessageAnimationIdentity>
  ) -> SendMessageAnimationListRemainder {
    SendMessageAnimationListRemainder(
      items: items.intersection(candidateItems),
      identities: identities.intersection(candidateIdentities)
    )
  }

  mutating func subtract(_ remainder: SendMessageAnimationListRemainder) {
    items.subtract(remainder.items)
    identities.subtract(remainder.identities)
  }
}
