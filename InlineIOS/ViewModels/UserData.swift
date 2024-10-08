import Foundation

public class UserData: ObservableObject, @unchecked Sendable {
    @Published var userId: Int64? = nil

    public func setId(_ id: Int64) {
        userId = id
    }

    public func getId() -> Int64? {
        return userId
    }
}
