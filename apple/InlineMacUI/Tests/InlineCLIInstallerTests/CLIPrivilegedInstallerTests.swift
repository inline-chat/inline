@testable import InlineCLIInstaller
import Foundation
import Security
import Testing

@Suite("Inline CLI administrator install")
struct CLIPrivilegedInstallerTests {
  /// Any Apple platform binary keeps its signature when copied.
  private static let appleSignedSource = URL(fileURLWithPath: "/bin/ls")
  private static let inlineRequirement = CLIExecutableVerifier.installRequirement(.production)

  private struct ScriptRun {
    let status: Int32
    let standardError: String
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "cli-privileged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Runs the root-side script as the current user; root is not needed for its logic.
  private func runScript(source: URL, destination: URL, requirement: String) throws -> ScriptRun {
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", CLIPrivilegedInstaller.script, "inline-cli-install",
      source.path, destination.path, CLIPrivilegedInstaller.stagingURL(for: destination).path, requirement,
    ]
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let output = (try? standardError.fileHandleForReading.readToEnd()) ?? Data()
    return ScriptRun(status: process.terminationStatus, standardError: String(decoding: output, as: UTF8.self))
  }

  private func leftoverStagingFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".inline.installing-") }
  }

  @Test("replaces the destination with a copy that satisfies the requirement")
  func replacesWithVerifiedCopy() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "inline")
    try Data("old".utf8).write(to: destination)

    let run = try runScript(source: Self.appleSignedSource, destination: destination, requirement: "anchor apple")

    #expect(run.status == 0)
    #expect(FileManager.default.contentsEqual(atPath: destination.path, andPath: Self.appleSignedSource.path))
    #expect(FileManager.default.isExecutableFile(atPath: destination.path))
    #expect(try leftoverStagingFiles(in: root).isEmpty)
  }

  @Test("rejects a binary not signed by Inline and leaves the destination unchanged")
  func rejectsForeignSignature() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "inline")
    try Data("old".utf8).write(to: destination)

    let run = try runScript(source: Self.appleSignedSource, destination: destination, requirement: Self.inlineRequirement)

    #expect(run.status == CLIPrivilegedInstaller.signatureRejectedStatus)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try leftoverStagingFiles(in: root).isEmpty)
  }

  @Test("refuses to replace a symlink or directory")
  func refusesUnsafeDestination() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appending(path: "inline")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "elsewhere"))
    let directory = root.appending(path: "folder")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

    for destination in [link, directory] {
      let run = try runScript(source: Self.appleSignedSource, destination: destination, requirement: "anchor apple")
      #expect(run.status == CLIPrivilegedInstaller.unsafeDestinationStatus)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == root.appending(path: "elsewhere").path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test("AppleScript passes paths with spaces and quotes through to the shell intact")
  func appleScriptQuotesArguments() throws {
    let root = try makeRoot().appending(path: "it's a \"bin\" dir")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let source = root.appending(path: "source binary")
    try FileManager.default.copyItem(at: Self.appleSignedSource, to: source)
    let destination = root.appending(path: "inline")

    // Same arguments as the real call, minus the elevation, so no prompt appears.
    var arguments = CLIPrivilegedInstaller.arguments(for: .init(
      sourceURL: source,
      destinationURL: destination,
      codeRequirement: "anchor apple",
      prompt: "unused"
    ))
    let elevated = try #require(arguments.firstIndex { $0.contains("with administrator privileges") })
    arguments[elevated] = "do shell script command"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(FileManager.default.contentsEqual(atPath: destination.path, andPath: source.path))
  }

  @Test("maps osascript errors to install outcomes")
  func mapsOsascriptErrors() {
    #expect(CLIPrivilegedInstaller.failure(fromStandardError: "0:120: execution error: User canceled. (-128)\n") == .canceled)
    #expect(CLIPrivilegedInstaller.failure(fromStandardError: "execution error: The CLI was not signed by Inline. (65)") == .signatureRejected)
    #expect(CLIPrivilegedInstaller.failure(fromStandardError: "execution error: The existing item is not a regular file. (66)") == .unsafeDestination)
    #expect(CLIPrivilegedInstaller.failure(fromStandardError: "execution error: install: denied (71)") == .failed("execution error: install: denied (71)"))
  }

  @Test("only an existing read-only directory needs an administrator")
  func detectsAdministratorDirectories() throws {
    let root = try makeRoot()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
      try? FileManager.default.removeItem(at: root)
    }
    let destination = root.appending(path: "inline")
    #expect(!CLIInstallerService.requiresAdministrator(toInstallAt: destination))
    #expect(!CLIInstallerService.requiresAdministrator(toInstallAt: root.appending(path: "missing/inline")))

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    #expect(CLIInstallerService.requiresAdministrator(toInstallAt: destination))
  }

  @Test("install requirement covers current and legacy identifiers from Inline's team")
  func installRequirementParses() {
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(Self.inlineRequirement as CFString, [], &requirement) == errSecSuccess)
    #expect(Self.inlineRequirement.contains("identifier \"chat.inline.cli\""))
    #expect(Self.inlineRequirement.contains("identifier \"inline\""))
    #expect(Self.inlineRequirement.contains("certificate leaf[subject.OU] = \"2487AN8AL4\""))
  }
}
