import InlineKit

enum ReactionChipOrdering {
  static func sortForLayout(_ groups: [GroupedReaction]) -> [GroupedReaction] {
    groups.sorted { lhs, rhs in
      if lhs.reactions.count != rhs.reactions.count { return lhs.reactions.count > rhs.reactions.count }
      return lhs.emoji < rhs.emoji
    }
  }
}

