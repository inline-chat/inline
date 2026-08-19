import Foundation
import Logger

public class UserData: ObservableObject, @unchecked Sendable {
  @Published var userId: Int64? = nil

  public func setId(_ id: Int64) {
    Log.shared.debug("USERID SAVED \(id)")
    userId = id
  }

  public func getId() -> Int64? {
    Log.shared.debug("USERID GOTTEN \(String(describing: userId))")
    return userId
  }
}
