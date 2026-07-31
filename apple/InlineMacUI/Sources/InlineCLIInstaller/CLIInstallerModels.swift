import Foundation

public struct CLIInstallerConfiguration: Sendable {
  public let manifestURL: URL
  public let documentationURL: URL
  public let expectedSigningIdentifier: String
  public let legacySigningIdentifiers: Set<String>
  public let expectedTeamIdentifier: String
  public let installLocations: [URL]
  public let searchesEnvironmentPath: Bool
  public let maximumManifestBytes: Int
  public let maximumArtifactBytes: Int64

  public init(
    manifestURL: URL,
    documentationURL: URL,
    expectedSigningIdentifier: String,
    legacySigningIdentifiers: Set<String> = [],
    expectedTeamIdentifier: String,
    installLocations: [URL],
    searchesEnvironmentPath: Bool = true,
    maximumManifestBytes: Int = 1_000_000,
    maximumArtifactBytes: Int64 = 100_000_000
  ) {
    self.manifestURL = manifestURL
    self.documentationURL = documentationURL
    self.expectedSigningIdentifier = expectedSigningIdentifier
    self.legacySigningIdentifiers = legacySigningIdentifiers
    self.expectedTeamIdentifier = expectedTeamIdentifier
    self.installLocations = installLocations
    self.searchesEnvironmentPath = searchesEnvironmentPath
    self.maximumManifestBytes = maximumManifestBytes
    self.maximumArtifactBytes = maximumArtifactBytes
  }

  public static var production: CLIInstallerConfiguration {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return CLIInstallerConfiguration(
      manifestURL: URL(string: "https://public-assets.inline.chat/cli/manifest.json")!,
      documentationURL: URL(string: "https://inline.chat/docs/cli")!,
      expectedSigningIdentifier: "chat.inline.cli",
      legacySigningIdentifiers: ["inline"],
      expectedTeamIdentifier: "2487AN8AL4",
      installLocations: [
        URL(fileURLWithPath: "/usr/local/bin/inline"),
        home.appending(path: ".local/bin/inline"),
        URL(fileURLWithPath: "/opt/homebrew/bin/inline"),
      ]
    )
  }
}

public enum CLIInstallationSource: String, Equatable, Sendable {
  case inline
  case homebrew
  case external
}

public struct CLIInstallation: Equatable, Sendable {
  public let executableURL: URL
  public let version: String?
  public let source: CLIInstallationSource
  public let isOnPath: Bool

  public init(
    executableURL: URL,
    version: String?,
    source: CLIInstallationSource,
    isOnPath: Bool
  ) {
    self.executableURL = executableURL
    self.version = version
    self.source = source
    self.isOnPath = isOnPath
  }
}

public struct CLIRelease: Equatable, Sendable {
  public let version: String
  public let archiveURL: URL
  public let sha256: String
  public let size: Int64?

  public init(version: String, archiveURL: URL, sha256: String, size: Int64?) {
    self.version = version
    self.archiveURL = archiveURL
    self.sha256 = sha256
    self.size = size
  }
}

public enum CLIInstallDisposition: Equatable, Sendable {
  case install
  case update
  case current
  case packageManaged
  case conflictingInstallation
}

public struct CLIInstallPlan: Equatable, Sendable {
  public let localInstallation: CLIInstallation?
  public let release: CLIRelease
  public let destinationURL: URL?
  public let disposition: CLIInstallDisposition

  public init(
    localInstallation: CLIInstallation?,
    release: CLIRelease,
    destinationURL: URL?,
    disposition: CLIInstallDisposition
  ) {
    self.localInstallation = localInstallation
    self.release = release
    self.destinationURL = destinationURL
    self.disposition = disposition
  }
}

public struct CLIInstallerFailure: Error, Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case operationInProgress
    case network
    case invalidManifest
    case unsupportedArchitecture
    case invalidArchive
    case checksumMismatch
    case invalidSignature
    case conflictingInstallation
    case packageManaged
    case permissionDenied
    case installationFailed
  }

  public let kind: Kind
  public let title: String
  public let message: String
  public let recoveryURL: URL

  public init(kind: Kind, title: String, message: String, recoveryURL: URL) {
    self.kind = kind
    self.title = title
    self.message = message
    self.recoveryURL = recoveryURL
  }
}

public enum CLIInstallerPhase: Equatable, Sendable {
  case idle
  case checkingLocal
  case checkingRemote
  case ready(CLIInstallPlan)
  case downloading(version: String, expectedBytes: Int64?)
  case verifying(version: String)
  case installing(destinationURL: URL)
  case installed(CLIInstallation)
  case failed(CLIInstallerFailure)

  public var isBusy: Bool {
    switch self {
    case .checkingLocal, .checkingRemote, .downloading, .verifying, .installing:
      true
    case .idle, .ready, .installed, .failed:
      false
    }
  }

  public var menuTitle: String {
    switch self {
    case .idle:
      "Install Inline CLI…"
    case .checkingLocal, .checkingRemote:
      "Checking Inline CLI…"
    case let .ready(plan):
      switch plan.disposition {
      case .install:
        "Install Inline CLI…"
      case .update:
        "Update Inline CLI…"
      case .current:
        "Inline CLI Installed"
      case .packageManaged:
        "Update Inline CLI with Homebrew…"
      case .conflictingInstallation:
        "Resolve Inline CLI Installation…"
      }
    case let .downloading(version, _):
      "Downloading Inline CLI \(version)…"
    case .verifying:
      "Verifying Inline CLI…"
    case .installing:
      "Installing Inline CLI…"
    case .installed:
      "Inline CLI Installed"
    case .failed:
      "Retry Install Inline CLI…"
    }
  }

  public var allowsPrimaryAction: Bool {
    switch self {
    case .idle, .failed:
      true
    case let .ready(plan):
      plan.disposition != .current
    case .checkingLocal, .checkingRemote, .downloading, .verifying, .installing, .installed:
      false
    }
  }
}

public enum CLIInstallResult: Equatable, Sendable {
  case installed(CLIInstallation)
  case alreadyInstalled(CLIInstallation)
  case failed(CLIInstallerFailure)
}

public struct CLIServiceInstallOutcome: Equatable, Sendable {
  public let installation: CLIInstallation
  public let didInstall: Bool

  public init(installation: CLIInstallation, didInstall: Bool) {
    self.installation = installation
    self.didInstall = didInstall
  }
}

public typealias CLIInstallerProgress = @MainActor @Sendable (CLIInstallerPhase) -> Void

public protocol CLIInstalling: Sendable {
  func check(progress: @escaping CLIInstallerProgress) async throws -> CLIInstallPlan
  func install(progress: @escaping CLIInstallerProgress) async throws -> CLIServiceInstallOutcome
}
