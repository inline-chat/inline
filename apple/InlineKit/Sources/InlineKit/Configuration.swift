import Foundation

public enum ProjectConfig {
  enum ConfigurationKey: String {
    case devHost = "DEV_HOST"
  }
  
  enum Error: Swift.Error {
    case missingKey, invalidValue
  }
  
  static func value<T>(for key: ConfigurationKey) throws -> T where T: LosslessStringConvertible {
    guard let object = Bundle.main.object(forInfoDictionaryKey: key.rawValue) else {
      throw Error.missingKey
    }
    
    switch object {
    case let value as T:
      return value
    case let string as String:
      guard let value = T(string) else { fallthrough }
      return value
    default:
      throw Error.invalidValue
    }
  }
  
  static public let devHost: String = {
    do {
      return try value(for: .devHost)
    } catch {
      fatalError("Failed to load dev host")
    }
  }()
}
