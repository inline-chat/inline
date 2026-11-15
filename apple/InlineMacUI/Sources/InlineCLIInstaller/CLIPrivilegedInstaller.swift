import Foundation

/// Replaces the CLI in a directory the user cannot write, typically a
/// root-owned `/usr/local/bin`, through the system administrator prompt.
///
/// This follows the pattern other Mac apps use for "install command in PATH":
/// an `osascript` `do shell script … with administrator privileges` call
/// rather than a persistent privileged helper. The root side receives paths
/// only as arguments, copies into a root-owned staging file, checks the
/// staged copy against Inline's code requirement, and only then renames it
/// over the destination, so a swapped source file can never land on PATH.
enum CLIPrivilegedInstaller {
  struct Request: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let codeRequirement: String
    let prompt: String
  }

  enum Failure: Error, Equatable {
    case canceled
    case signatureRejected
    case unsafeDestination
    case failed(String)
  }

  static let signatureRejectedStatus: Int32 = 65
  static let unsafeDestinationStatus: Int32 = 66

  /// Runs as root with `$1` source, `$2` destination, `$3` staging path in the
  /// destination directory, and `$4` code requirement text.
  static let script = """
  set -eu
  src="$1"; dst="$2"; staged="$3"; requirement="$4"
  if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
    echo "The existing item is not a regular file." >&2
    exit \(unsafeDestinationStatus)
  fi
  rm -f "$staged"
  trap 'rm -f "$staged"' EXIT
  /usr/bin/install -m 0755 "$src" "$staged"
  if ! /usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$staged" 2>/dev/null; then
    echo "The CLI was not signed by Inline." >&2
    exit \(signatureRejectedStatus)
  fi
  /bin/mv -f "$staged" "$dst"
  """

  static let appleScript = [
    "on run argv",
    "set command to \"/bin/sh -c \" & quoted form of (item 1 of argv) & \" inline-cli-install\""
      + " & \" \" & quoted form of (item 2 of argv)"
      + " & \" \" & quoted form of (item 3 of argv)"
      + " & \" \" & quoted form of (item 4 of argv)"
      + " & \" \" & quoted form of (item 5 of argv)",
    "do shell script command with prompt (item 6 of argv) with administrator privileges",
    "end run",
  ]

  /// The sandboxed build cannot elevate; the prompt would never appear.
  static var isAvailable: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
  }

  static func stagingURL(for destinationURL: URL) -> URL {
    destinationURL.deletingLastPathComponent()
      .appending(path: ".inline.installing-\(UUID().uuidString)")
  }

  static func arguments(for request: Request) -> [String] {
    appleScript.flatMap { ["-e", $0] } + [
      script,
      request.sourceURL.path,
      request.destinationURL.path,
      stagingURL(for: request.destinationURL).path,
      request.codeRequirement,
      request.prompt,
    ]
  }

  /// Maps `osascript` output: `do shell script` reports the shell's exit
  /// status in parentheses, and a dismissed prompt reports -128.
  static func failure(fromStandardError standardError: String) -> Failure {
    let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.hasSuffix("(-128)") { return .canceled }
    if message.hasSuffix("(\(signatureRejectedStatus))") { return .signatureRejected }
    if message.hasSuffix("(\(unsafeDestinationStatus))") { return .unsafeDestination }
    return .failed(message)
  }

  static func run(_ request: Request) async throws {
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = arguments(for: request)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = standardError
    let handle = ProcessHandle(process)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { finished in
          let output = (try? standardError.fileHandleForReading.readToEnd()) ?? Data()
          if finished.terminationReason == .exit, finished.terminationStatus == 0 {
            continuation.resume()
          } else if finished.terminationReason == .uncaughtSignal {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume(throwing: failure(fromStandardError: String(decoding: output, as: UTF8.self)))
          }
        }
        do {
          try process.run()
          try? standardError.fileHandleForWriting.close()
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: Failure.failed(error.localizedDescription))
        }
      }
    } onCancel: {
      // Ending osascript dismisses its authorization prompt.
      handle.terminate()
    }
  }
}

private final class ProcessHandle: @unchecked Sendable {
  private let process: Process

  init(_ process: Process) { self.process = process }

  func terminate() {
    if process.isRunning { process.terminate() }
  }
}
