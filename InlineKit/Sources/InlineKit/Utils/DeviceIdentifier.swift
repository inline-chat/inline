import Foundation

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
  
  public func getIdentifier() throws -> String {
    #if os(iOS) || os(tvOS)
      if let idfv = UIDevice.current.identifierForVendor?.uuidString {
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
