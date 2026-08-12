import InlineProtocol

public enum ScopeID: Hashable, Identifiable, Sendable {
  case user(Int64)
  case space(Int64)

  public var id: Self { self }

  public var spaceID: Int64? {
    guard case let .space(id) = self else { return nil }
    return id
  }
}

/// A resolved user or space boundary shared by scoped client features.
public enum Scope: Hashable, Identifiable, Sendable {
  case user(UserInfo)
  case space(Space)

  public var id: ScopeID {
    switch self {
      case let .user(user): .user(user.id)
      case let .space(space): .space(space.id)
    }
  }

  public var name: String {
    switch self {
      case .user: "Personal"
      case let .space(space): space.displayName
    }
  }

  var protocolValue: InlineProtocol.InputScope {
    .with {
      switch self {
        case let .user(user):
          $0.user.userID = user.id
        case let .space(space):
          $0.space.spaceID = space.id
      }
    }
  }

  init?(protocolValue: InlineProtocol.Scope) {
    switch protocolValue.type {
      case let .user(value) where value.hasUser:
        self = .user(UserInfo(user: User(from: value.user)))
      case let .space(value) where value.hasSpace:
        self = .space(Space(from: value.space))
      default:
        return nil
    }
  }
}
