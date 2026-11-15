import Foundation
import InlineNotificationFence
#if canImport(UIKit)
import UIKit
#endif

enum DeviceIdentifierError: Error {
  case identifierUnavailable
}

public actor DeviceIdentifier {
  public static let shared = DeviceIdentifier()

  private let idKey = "device_identifier"
  private let defaults: UserDefaults

  private init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func getIdentifier() async throws -> String {
    let identifier = try await createOrRetrieveIdentifier()
    return identifier
  }

  private func createOrRetrieveIdentifier() async throws -> String {
    #if os(iOS) || os(tvOS)
    let idfv = await MainActor.run {
      UIDevice.current.identifierForVendor?.uuidString
    }
    if let idfv {
      // The vendor ID is shared by every Inline build on the device. The server replaces a
      // session on the same device and account, so a Debug login must not sign Release out.
      let identifier = InlineInstallNamespace.scoped(idfv)
      defaults.set(identifier, forKey: idKey)
      return identifier
    }
    #endif

    if let storedId = defaults.string(forKey: idKey) {
      return storedId
    }

    let newId = UUID().uuidString
    defaults.set(newId, forKey: idKey)
    return newId
  }
}
