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
  
  public static let devHost: String = {
    do {
      return try value(for: .devHost)
    } catch {
      fatalError("Failed to load dev host")
    }
  }()
  
  public enum KnownArgumentKeys: String {
    case userProfile = "user-profile"
  }
  
  // Helper function to get named arguments
  public static func getArgumentValue(for key: KnownArgumentKeys) -> String? {
    let args = CommandLine.arguments
    print(args)
    let keyPrefix = "--\(key.rawValue)"
    if let index = args.firstIndex(where: { $0.starts(with: keyPrefix) }),
       index + 1 < args.count
    {
      return args[index]
        // For flags with value
        .replacingOccurrences(of: "\(keyPrefix)=", with: "")
        // For booleans flags without value
        .replacingOccurrences(of: "\(keyPrefix)", with: "")
    }
    return nil
  }
  
  public static var userProfile: String? {
    getArgumentValue(for: .userProfile)
  }
}
