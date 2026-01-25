public struct ConnectionConstraints: Sendable, Equatable {
  public var authAvailable: Bool
  public var networkAvailable: Bool
  public var appActive: Bool
  public var userWantsConnection: Bool

  public init(
    authAvailable: Bool,
    networkAvailable: Bool,
    appActive: Bool,
    userWantsConnection: Bool
  ) {
    self.authAvailable = authAvailable
    self.networkAvailable = networkAvailable
    self.appActive = appActive
    self.userWantsConnection = userWantsConnection
  }

  public static let initial = ConnectionConstraints(
    authAvailable: false,
    networkAvailable: true,
    appActive: true,
    userWantsConnection: true
  )

  public var isSatisfied: Bool {
    authAvailable && networkAvailable && appActive && userWantsConnection
  }
}
