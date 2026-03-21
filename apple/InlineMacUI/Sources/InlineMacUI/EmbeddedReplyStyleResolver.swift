public enum EmbeddedReplyStyleAppearance: Equatable {
  case colored
  case white
}

public enum EmbeddedReplyStyleResolver {
  public static func appearance(
    isOutgoing: Bool,
    hasPhoto: Bool,
    hasText: Bool
  ) -> EmbeddedReplyStyleAppearance {
    if isOutgoing, !(hasPhoto && !hasText) {
      return .white
    }

    return .colored
  }
}
