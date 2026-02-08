import Foundation
import Darwin

public enum ProjectConfig {
  enum ConfigurationKey: String {
    case devHost = "DEV_HOST"
    case useProductionApi = "USE_PRODUCTION_API"
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

  public static let devHost: String =
    (try? value(for: .devHost)) ?? "localhost"

  public static let useProductionApi: Bool = {
    #if DEBUG
    let fallback = false
    #else
    let fallback = true
    #endif
    let valueFromConfig: String? = try? value(
      for: .useProductionApi
    )
    return valueFromConfig == nil ? fallback : (valueFromConfig == "YES")
  }()

  public enum KnownArgumentKeys: String {
    case userProfile = "user-profile"
  }

  // Helper function to get named arguments
  public static func getArgumentValue(for key: KnownArgumentKeys) -> String? {
    let args = CommandLine.arguments
    let keyPrefix = "--\(key.rawValue)"
    guard let index = args.firstIndex(where: { $0.starts(with: keyPrefix) }) else {
      return nil
    }

    let current = args[index]

    // Support: `--key=value`
    if current.starts(with: "\(keyPrefix)=") {
      return current.replacingOccurrences(of: "\(keyPrefix)=", with: "")
    }

    // Support: `--key value`
    if current == keyPrefix, index + 1 < args.count {
      return args[index + 1]
    }

    // Support: `--key` (boolean flag)
    if current == keyPrefix {
      return ""
    }

    // Support legacy: `--key<value>` (should not happen, but keep compatibility)
    return current.replacingOccurrences(of: keyPrefix, with: "")
  }

  public static var userProfile: String? {
    if let env = getenv("INLINE_USER_PROFILE"),
       let value = String(validatingCString: env),
       value.isEmpty == false
    {
      return value
    }

    let arg = getArgumentValue(for: .userProfile)
    return arg?.isEmpty == true ? nil : arg
  }
}
