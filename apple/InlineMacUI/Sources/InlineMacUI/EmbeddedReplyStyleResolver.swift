public enum EmbeddedReplyStyleAppearance: Equatable {
  case colored
  case white
}

public enum EmbeddedReplyStyleResolver {
  public static func appearance(
    isOutgoing: Bool,
    hasPhoto: Bool,
    hasText: Bool,
    hasBubbleColor: Bool = true
  ) -> EmbeddedReplyStyleAppearance {
    if isOutgoing, hasBubbleColor, !(hasPhoto && !hasText) {
      return .white
    }

    return .colored
  }
}
