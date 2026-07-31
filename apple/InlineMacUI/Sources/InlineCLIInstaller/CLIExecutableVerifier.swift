import Foundation
import Security

enum CLIExecutableVerifier {
  static func verify(
    _ executableURL: URL,
    configuration: CLIInstallerConfiguration,
    allowLegacyAdHoc: Bool = false
  ) throws {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw invalidSignature(configuration)
    }

    var validationError: Unmanaged<CFError>?
    let integrityStatus = SecStaticCodeCheckValidityWithErrors(
      staticCode,
      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
      nil,
      &validationError
    )
    guard integrityStatus == errSecSuccess else {
      throw invalidSignature(configuration)
    }

    var signingInformation: CFDictionary?
    let informationStatus = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard informationStatus == errSecSuccess,
          let information = signingInformation as NSDictionary?,
          let identifier = information[kSecCodeInfoIdentifier] as? String else {
      throw invalidSignature(configuration)
    }

    let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
    if allowLegacyAdHoc, teamIdentifier == nil, identifier.hasPrefix("inline-") {
      // Older CLI releases used a valid linker-generated ad-hoc signature.
      // This remains installation-migration-only and is never accepted when
      // handing a new credential to an executable.
      return
    }

    let acceptedIdentifiers = configuration.legacySigningIdentifiers
      .union([configuration.expectedSigningIdentifier])
    guard teamIdentifier == configuration.expectedTeamIdentifier,
          acceptedIdentifiers.contains(identifier) else {
      throw invalidSignature(configuration)
    }

    let escapedIdentifier = identifier.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedTeam = configuration.expectedTeamIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    let requirementText =
      "anchor apple generic and identifier \"\(escapedIdentifier)\" and certificate leaf[subject.OU] = \"\(escapedTeam)\""
    var requirement: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      requirementText as CFString,
      [],
      &requirement
    )
    guard requirementStatus == errSecSuccess, let requirement else {
      throw invalidSignature(configuration)
    }

    let validationStatus = SecStaticCodeCheckValidityWithErrors(
      staticCode,
      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
      requirement,
      &validationError
    )
    guard validationStatus == errSecSuccess else {
      throw invalidSignature(configuration)
    }
  }

  private static func invalidSignature(_ configuration: CLIInstallerConfiguration) -> CLIInstallerFailure {
    CLIInstallerFailure(
      kind: .invalidSignature,
      title: "Inline CLI Signature Couldn’t Be Verified",
      message: "The executable was not signed by Inline and was not used.",
      recoveryURL: configuration.documentationURL
    )
  }
}
