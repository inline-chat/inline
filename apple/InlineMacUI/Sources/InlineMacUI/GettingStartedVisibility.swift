@MainActor
public enum GettingStartedVisibility {
  private static var pendingUserID: Int64?

  public static func prepare(for userID: Int64, isNewSignup: Bool) {
    pendingUserID = isNewSignup ? userID : nil
  }

  public static func shouldShow(for userID: Int64) -> Bool {
    guard pendingUserID == userID else { return false }
    pendingUserID = nil
    return true
  }
}
