import CryptoKit
import Darwin
import Foundation

public actor CLIInstallerService: CLIInstalling {
  private struct ReleaseManifest: Decodable {
    let version: String
    let targets: [String: ReleaseTarget]
  }

  private struct ReleaseTarget: Decodable {
    let url: URL
    let sha256: String
    let size: Int64?
  }

  private struct ProcessOutput {
    let status: Int32
    let standardOutput: String
    let standardError: String
  }

  private let configuration: CLIInstallerConfiguration
  private let fileManager: FileManager
  private let session: URLSession

  public init(
    configuration: CLIInstallerConfiguration = .production,
    fileManager: FileManager = .default,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.fileManager = fileManager
    self.session = session
  }

  public func check(progress: @escaping CLIInstallerProgress) async throws -> CLIInstallPlan {
    await progress(.checkingLocal)
    let localInstallation = inspectLocalInstallation()

    await progress(.checkingRemote)
    let release = try await fetchRelease()
    return try makePlan(localInstallation: localInstallation, release: release)
  }

  public func install(progress: @escaping CLIInstallerProgress) async throws -> CLIServiceInstallOutcome {
    let plan = try await check(progress: progress)

    switch plan.disposition {
    case .current:
      guard let localInstallation = plan.localInstallation else {
        throw failure(
          .installationFailed,
          title: "Couldn’t Inspect Inline CLI",
          message: "Inline CLI was reported as installed, but its executable could not be found."
        )
      }
      return CLIServiceInstallOutcome(installation: localInstallation, didInstall: false)

    case .packageManaged:
      throw failure(
        .packageManaged,
        title: "Inline CLI Is Managed by Homebrew",
        message: "Update this Inline CLI installation with Homebrew, or use the manual installation instructions."
      )

    case .conflictingInstallation:
      let path = plan.localInstallation?.executableURL.path ?? "a directory on your PATH"
      throw failure(
        .conflictingInstallation,
        title: "Another Inline Command Was Found",
        message: "The existing executable at \(path) is not an Inline-signed CLI. It was left unchanged."
      )

    case .install, .update:
      break
    }

    guard let destinationURL = plan.destinationURL else {
      throw failure(
        .permissionDenied,
        title: "No Writable Installation Location",
        message: "Inline could not find a safe, writable location for the CLI."
      )
    }

    await progress(.downloading(version: plan.release.version, expectedBytes: plan.release.size))
    let workDirectory = fileManager.temporaryDirectory
      .appending(path: "inline-cli-installer-\(UUID().uuidString)", directoryHint: .isDirectory)

    do {
      try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: false)
    } catch {
      throw failure(
        .installationFailed,
        title: "Couldn’t Prepare Installation",
        message: "Inline could not create a temporary directory: \(error.localizedDescription)"
      )
    }
    defer { try? fileManager.removeItem(at: workDirectory) }

    let archiveURL = workDirectory.appending(path: "inline.tar.gz")
    try await download(plan.release, to: archiveURL)

    await progress(.verifying(version: plan.release.version))
    try verifyChecksum(of: archiveURL, expected: plan.release.sha256)
    let executableURL = try extractExecutable(from: archiveURL, in: workDirectory)
    try verifySignature(of: executableURL)

    let downloadedVersion = try readVersion(at: executableURL)
    guard downloadedVersion == plan.release.version else {
      throw failure(
        .invalidArchive,
        title: "Inline CLI Version Didn’t Match",
        message: "The release advertised version \(plan.release.version), but the downloaded CLI reported \(downloadedVersion ?? "an unknown version")."
      )
    }

    await progress(.installing(destinationURL: destinationURL))
    try installExecutable(executableURL, at: destinationURL)
    try verifySignature(of: destinationURL)

    let installedVersion = try readVersion(at: destinationURL)
    guard installedVersion == plan.release.version else {
      throw failure(
        .installationFailed,
        title: "Inline CLI Installation Couldn’t Be Verified",
        message: "The installed executable did not report the expected version."
      )
    }

    let installation = CLIInstallation(
      executableURL: destinationURL,
      version: installedVersion,
      source: .inline,
      isOnPath: pathContains(destinationURL.deletingLastPathComponent())
    )
    return CLIServiceInstallOutcome(installation: installation, didInstall: true)
  }

  private func fetchRelease() async throws -> CLIRelease {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(from: configuration.manifestURL)
    } catch {
      throw failure(
        .network,
        title: "Couldn’t Check for Inline CLI",
        message: "The release information could not be downloaded: \(error.localizedDescription)"
      )
    }

    try validateHTTPResponse(response, maximumBytes: Int64(configuration.maximumManifestBytes))
    guard data.count <= configuration.maximumManifestBytes else {
      throw invalidManifest("The release manifest was unexpectedly large.")
    }

    let manifest: ReleaseManifest
    do {
      manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
    } catch {
      throw invalidManifest("The release manifest could not be decoded.")
    }

    guard Self.parseVersion(manifest.version) != nil else {
      throw invalidManifest("The release manifest contained an invalid version.")
    }

    let targetName = try currentTargetName()
    guard let target = manifest.targets[targetName] else {
      throw failure(
        .unsupportedArchitecture,
        title: "This Mac Isn’t Supported",
        message: "The current Inline CLI release does not include \(targetName)."
      )
    }

    guard target.url.scheme == "https" else {
      throw invalidManifest("The CLI download URL was not secure.")
    }
    guard Self.isSHA256(target.sha256) else {
      throw invalidManifest("The CLI checksum was invalid.")
    }
    if let size = target.size, !(1 ... configuration.maximumArtifactBytes).contains(size) {
      throw invalidManifest("The CLI download size was invalid.")
    }

    return CLIRelease(
      version: manifest.version,
      archiveURL: target.url,
      sha256: target.sha256.lowercased(),
      size: target.size
    )
  }

  private func inspectLocalInstallation() -> CLIInstallation? {
    for candidate in localCandidateURLs() {
      guard fileManager.fileExists(atPath: candidate.path) else { continue }

      let resolvedURL = candidate.resolvingSymlinksInPath()
      let attributes = try? fileManager.attributesOfItem(atPath: candidate.path)
      let isSymbolicLink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
      let hasExpectedSignature = (try? verifySignature(of: candidate, allowLegacyAdHoc: true)) != nil
      let source: CLIInstallationSource
      if !hasExpectedSignature {
        source = .external
      } else if isSymbolicLink,
                !Self.isHomebrewPath(candidate.path),
                !Self.isHomebrewPath(resolvedURL.path) {
        source = .external
      } else if Self.isHomebrewPath(candidate.path) || Self.isHomebrewPath(resolvedURL.path) {
        source = .homebrew
      } else {
        source = .inline
      }

      let version = source == .external ? nil : try? readVersion(at: candidate)
      return CLIInstallation(
        executableURL: candidate,
        version: version,
        source: source,
        isOnPath: pathContains(candidate.deletingLastPathComponent())
      )
    }
    return nil
  }

  private func makePlan(localInstallation: CLIInstallation?, release: CLIRelease) throws -> CLIInstallPlan {
    guard let localInstallation else {
      return CLIInstallPlan(
        localInstallation: nil,
        release: release,
        destinationURL: chooseNewDestination(),
        disposition: .install
      )
    }

    switch localInstallation.source {
    case .external:
      return CLIInstallPlan(
        localInstallation: localInstallation,
        release: release,
        destinationURL: nil,
        disposition: .conflictingInstallation
      )

    case .homebrew:
      let disposition: CLIInstallDisposition = Self.isOlder(localInstallation.version, than: release.version)
        ? .packageManaged
        : .current
      return CLIInstallPlan(
        localInstallation: localInstallation,
        release: release,
        destinationURL: nil,
        disposition: disposition
      )

    case .inline:
      return CLIInstallPlan(
        localInstallation: localInstallation,
        release: release,
        destinationURL: localInstallation.executableURL,
        disposition: Self.isOlder(localInstallation.version, than: release.version) ? .update : .current
      )
    }
  }

  private func chooseNewDestination() -> URL? {
    for candidate in configuration.installLocations where !Self.isHomebrewPath(candidate.path) {
      let directory = candidate.deletingLastPathComponent()
      if fileManager.fileExists(atPath: directory.path) {
        if fileManager.isWritableFile(atPath: directory.path) {
          return candidate
        }
      } else if directory.path.hasPrefix(fileManager.homeDirectoryForCurrentUser.path + "/") {
        return candidate
      }
    }
    return nil
  }

  private func localCandidateURLs() -> [URL] {
    var candidates: [URL] = []
    if configuration.searchesEnvironmentPath {
      candidates.append(contentsOf: pathDirectories().map { $0.appending(path: "inline") })
    }
    candidates.append(contentsOf: configuration.installLocations)

    var seen = Set<String>()
    return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private func download(_ release: CLIRelease, to destinationURL: URL) async throws {
    let temporaryURL: URL
    let response: URLResponse
    do {
      (temporaryURL, response) = try await session.download(from: release.archiveURL)
    } catch {
      throw failure(
        .network,
        title: "Couldn’t Download Inline CLI",
        message: "The CLI archive could not be downloaded: \(error.localizedDescription)"
      )
    }

    try validateHTTPResponse(response, maximumBytes: configuration.maximumArtifactBytes)
    let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
    let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard (1 ... configuration.maximumArtifactBytes).contains(actualSize) else {
      throw failure(
        .invalidArchive,
        title: "Inline CLI Download Was Invalid",
        message: "The downloaded archive had an unexpected size."
      )
    }
    if let expectedSize = release.size, expectedSize != actualSize {
      throw failure(
        .invalidArchive,
        title: "Inline CLI Download Was Incomplete",
        message: "The downloaded archive size did not match the release manifest."
      )
    }

    do {
      try fileManager.copyItem(at: temporaryURL, to: destinationURL)
    } catch {
      throw failure(
        .installationFailed,
        title: "Couldn’t Prepare Inline CLI",
        message: "The downloaded archive could not be staged: \(error.localizedDescription)"
      )
    }
  }

  private func validateHTTPResponse(_ response: URLResponse, maximumBytes: Int64) throws {
    guard let response = response as? HTTPURLResponse,
          response.url?.scheme == "https",
          (200 ... 299).contains(response.statusCode) else {
      throw failure(
        .network,
        title: "Inline CLI Download Failed",
        message: "The download server returned an unexpected response."
      )
    }
    if response.expectedContentLength > maximumBytes {
      throw failure(
        .invalidArchive,
        title: "Inline CLI Download Was Too Large",
        message: "The download server reported an unexpectedly large response."
      )
    }
  }

  private func verifyChecksum(of archiveURL: URL, expected: String) throws {
    let data: Data
    do {
      data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    } catch {
      throw failure(
        .invalidArchive,
        title: "Couldn’t Read Inline CLI Download",
        message: "The downloaded archive could not be read."
      )
    }

    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expected.lowercased() else {
      throw failure(
        .checksumMismatch,
        title: "Inline CLI Download Couldn’t Be Verified",
        message: "The downloaded archive did not match the release checksum and was not installed."
      )
    }
  }

  private func extractExecutable(from archiveURL: URL, in workDirectory: URL) throws -> URL {
    let listing = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
      arguments: ["-tzf", archiveURL.path]
    )
    guard listing.status == 0 else {
      throw invalidArchive("The downloaded archive could not be inspected.")
    }

    let entries = listing.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
    guard entries.count == 1, entries[0] == "inline" || entries[0] == "./inline" else {
      throw invalidArchive("The downloaded archive did not contain exactly one Inline CLI executable.")
    }

    let extractionDirectory = workDirectory.appending(path: "extracted", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: false)
    let extraction = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
      arguments: ["-xzf", archiveURL.path, "-C", extractionDirectory.path, entries[0]]
    )
    guard extraction.status == 0 else {
      throw invalidArchive("The downloaded archive could not be extracted.")
    }

    let executableURL = extractionDirectory.appending(path: "inline")
    let attributes = try fileManager.attributesOfItem(atPath: executableURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw invalidArchive("The archive’s Inline CLI entry was not a regular file.")
    }
    return executableURL
  }

  private func verifySignature(of executableURL: URL, allowLegacyAdHoc: Bool = false) throws {
    try CLIExecutableVerifier.verify(
      executableURL,
      configuration: configuration,
      allowLegacyAdHoc: allowLegacyAdHoc
    )
  }

  private func installExecutable(_ executableURL: URL, at destinationURL: URL) throws {
    let directoryURL = destinationURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
    } catch {
      throw permissionFailure(destinationURL, error: error)
    }

    if fileManager.fileExists(atPath: destinationURL.path) {
      let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw failure(
          .conflictingInstallation,
          title: "Existing Inline CLI Was Left Unchanged",
          message: "The item at \(destinationURL.path) is not a regular file."
        )
      }
      try verifySignature(of: destinationURL, allowLegacyAdHoc: true)
    }

    let stagedURL = directoryURL.appending(path: ".inline.installing-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: stagedURL) }

    do {
      try fileManager.copyItem(at: executableURL, to: stagedURL)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)
      try verifySignature(of: stagedURL)

      if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
      } else {
        try fileManager.moveItem(at: stagedURL, to: destinationURL)
      }
    } catch let failure as CLIInstallerFailure {
      throw failure
    } catch {
      throw permissionFailure(destinationURL, error: error)
    }
  }

  private func readVersion(at executableURL: URL) throws -> String? {
    let output = try runProcess(executableURL: executableURL, arguments: ["--version"])
    guard output.status == 0 else { return nil }
    return Self.versionString(in: output.standardOutput + " " + output.standardError)
  }

  private func runProcess(executableURL: URL, arguments: [String]) throws -> ProcessOutput {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let completion = DispatchSemaphore(value: 0)
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in completion.signal() }

    try process.run()
    if completion.wait(timeout: .now() + 10) == .timedOut {
      process.terminate()
      if completion.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = completion.wait(timeout: .now() + 1)
      }
      throw failure(
        .installationFailed,
        title: "Inline CLI Check Timed Out",
        message: "\(executableURL.lastPathComponent) did not finish in time."
      )
    }
    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return ProcessOutput(
      status: process.terminationStatus,
      standardOutput: String(data: outputData, encoding: .utf8) ?? "",
      standardError: String(data: errorData, encoding: .utf8) ?? ""
    )
  }

  private func pathContains(_ directoryURL: URL) -> Bool {
    let directoryPath = directoryURL.standardizedFileURL.path
    return pathDirectories().contains { $0.standardizedFileURL.path == directoryPath }
  }

  private func pathDirectories() -> [URL] {
    var paths: [String] = []
    if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
      paths.append(contentsOf: environmentPath.split(separator: ":").map(String.init))
    }

    paths.append(contentsOf: pathFileEntries(at: URL(fileURLWithPath: "/etc/paths")))
    let pathsDirectory = URL(fileURLWithPath: "/etc/paths.d", isDirectory: true)
    if let files = try? fileManager.contentsOfDirectory(
      at: pathsDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        paths.append(contentsOf: pathFileEntries(at: file))
      }
    }

    var seen = Set<String>()
    return paths.map(URL.init(fileURLWithPath:)).filter {
      seen.insert($0.standardizedFileURL.path).inserted
    }
  }

  private func pathFileEntries(at fileURL: URL) -> [String] {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    return contents.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
  }

  private func currentTargetName() throws -> String {
    #if arch(arm64)
    return "aarch64-apple-darwin"
    #elseif arch(x86_64)
    return "x86_64-apple-darwin"
    #else
    throw failure(
      .unsupportedArchitecture,
      title: "This Mac Isn’t Supported",
      message: "Inline CLI is not available for this Mac’s processor architecture."
    )
    #endif
  }

  private func invalidManifest(_ message: String) -> CLIInstallerFailure {
    failure(.invalidManifest, title: "Invalid Inline CLI Release", message: message)
  }

  private func invalidArchive(_ message: String) -> CLIInstallerFailure {
    failure(.invalidArchive, title: "Invalid Inline CLI Download", message: message)
  }

  private func permissionFailure(_ destinationURL: URL, error: any Error) -> CLIInstallerFailure {
    failure(
      .permissionDenied,
      title: "Inline CLI Couldn’t Be Installed",
      message: "Inline could not write to \(destinationURL.path): \(error.localizedDescription)"
    )
  }

  private func failure(
    _ kind: CLIInstallerFailure.Kind,
    title: String,
    message: String
  ) -> CLIInstallerFailure {
    CLIInstallerFailure(
      kind: kind,
      title: title,
      message: message,
      recoveryURL: configuration.documentationURL
    )
  }

  static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }

  static func isHomebrewPath(_ path: String) -> Bool {
    path == "/opt/homebrew/bin/inline"
      || path.contains("/Homebrew/")
      || path.contains("/Caskroom/")
      || path.contains("/Cellar/")
  }

  static func versionString(in output: String) -> String? {
    for token in output.split(whereSeparator: { $0.isWhitespace }) {
      let candidate = token.first == "v" ? token.dropFirst() : token[...]
      let trimmed = candidate.prefix { $0.isNumber || $0 == "." }
      if parseVersion(String(trimmed)) != nil {
        return String(trimmed)
      }
    }
    return nil
  }

  static func parseVersion(_ value: String) -> [Int]? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2, components.count <= 4 else { return nil }
    let numbers = components.compactMap { Int($0) }
    return numbers.count == components.count ? numbers : nil
  }

  static func isOlder(_ installedVersion: String?, than releaseVersion: String) -> Bool {
    guard var installed = installedVersion.flatMap(parseVersion), var release = parseVersion(releaseVersion) else {
      return true
    }
    let count = max(installed.count, release.count)
    installed += repeatElement(0, count: count - installed.count)
    release += repeatElement(0, count: count - release.count)
    return installed.lexicographicallyPrecedes(release)
  }
}
