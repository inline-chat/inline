import Combine
import Foundation

public final class CurrentDataModel: ObservableObject, @unchecked Sendable {
    public static let shared = CurrentDataModel()

    @Published public var token: String? = nil

    public func saveToken(_ token: String) {
        self.token = token
    }

    public init() {}
}
