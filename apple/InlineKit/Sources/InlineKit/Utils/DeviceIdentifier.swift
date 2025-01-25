import Foundation
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
      defaults.set(idfv, forKey: idKey)
      return idfv
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
