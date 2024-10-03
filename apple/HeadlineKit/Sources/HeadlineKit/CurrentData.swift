import Combine
import Foundation

public final class CurrentDataModel: ObservableObject, @unchecked Sendable {
    public static let shared = CurrentDataModel()

    @Published public var token: String? = nil

    public func saveToken(_ token: String) {
        print("💶 TOKEN before saving\(self.token)")
        self.token = token
        print("💶 TOKEN \(token)")
        print("💶 TOKEN Self \(self.token)")
    }

    public init() {}
}
