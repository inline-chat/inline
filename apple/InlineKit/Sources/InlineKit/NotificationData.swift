import Foundation

public class NotificationData: Codable, ObservableObject, @unchecked Sendable {
  public private(set) var deviceId: String?
  public private(set) var deviceName: String?
  public private(set) var deviceToken: String?

  public func set(
    deviceId: String? = nil,
    deviceName: String? = nil,
    deviceToken: String? = nil
  ) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.deviceToken = deviceToken
  }

  public static let shared = NotificationData()
}
