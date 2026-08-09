import InlineCLIInstaller
import SwiftUI

struct CLIInstallerView: View {
  static let contentSize = CGSize(width: 460, height: 300)

  let model: CLIInstallerModel
  let installer: CLIInstallerController
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      CLIInstallerContent(
        phase: model.phase,
        installerPhase: installer.phase
      )
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Divider()

      CLIInstallerActions(model: model, dismiss: dismiss)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    .frame(width: Self.contentSize.width, height: Self.contentSize.height)
  }
}

private struct CLIInstallerContent: View {
  let phase: CLIInstallerModel.Phase
  let installerPhase: CLIInstallerPhase

  var body: some View {
    switch phase {
    case .idle, .installing:
      CLIInstallerStandardContent(
        title: "Install Inline CLI",
        progress: installProgress,
        message: installMessage
      )
    case .signingIn:
      CLIInstallerStandardContent(
        title: "Sign In to Inline CLI",
        progress: 0.9,
        message: "Signing in automatically…"
      )
    case let .ready(installation, authentication):
      CLIInstallerReadyContent(
        installation: installation,
        authentication: authentication
      )
    case let .signInNeeded(installation, issue):
      CLIInstallerSignInContent(
        installation: installation,
        issue: issue
      )
    case let .failed(failure):
      CLIInstallerFailureContent(failure: failure)
    case .cancelled:
      CLIInstallerStandardContent(
        title: "Setup Cancelled",
        progress: 0,
        message: "You can try again at any time."
      )
    }
  }

  private var installProgress: Double {
    switch installerPhase {
    case .idle:
      0.02
    case .checkingLocal:
      0.08
    case .checkingRemote:
      0.18
    case .ready:
      0.25
    case .downloading:
      0.45
    case .verifying:
      0.65
    case .installing:
      0.78
    case .installed:
      0.84
    case .failed:
      0
    }
  }

  private var installMessage: LocalizedStringResource {
    switch installerPhase {
    case .idle:
      "Starting installation…"
    case .checkingLocal:
      "Checking for an existing installation…"
    case .checkingRemote:
      "Checking for the latest release…"
    case .ready:
      "Preparing installation…"
    case .downloading:
      "Downloading Inline CLI…"
    case .verifying:
      "Verifying the download…"
    case .installing:
      "Installing Inline CLI…"
    case .installed:
      "Finishing installation…"
    case .failed:
      "Installation stopped."
    }
  }
}

private struct CLIInstallerStandardContent: View {
  let title: LocalizedStringResource
  let progress: Double
  let message: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.title2.weight(.semibold))

      ProgressView(value: progress)
        .progressViewStyle(.linear)

      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CLIInstallerReadyContent: View {
  let installation: CLIInstallation
  let authentication: CLIAuthBootstrapResult

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Inline CLI Is Ready")
        .font(.title2.weight(.semibold))

      ProgressView(value: 1)
        .progressViewStyle(.linear)

      Text("Inline CLI is installed and signed in.")
        .font(.callout)
        .foregroundStyle(.secondary)

      if let warning = authentication.warning {
        Text(warning)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      if !installation.isOnPath {
        Text("Add the install directory to PATH before running `inline` by name.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CLIInstallerSignInContent: View {
  let installation: CLIInstallation
  let issue: CLIInstallerModel.SignInIssue

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Finish Sign-In in Terminal")
        .font(.title2.weight(.semibold))

      ProgressView(value: 0.9)
        .progressViewStyle(.linear)

      CLIInstallerSignInMessage(issue: issue)

      Text("Run in Terminal:")
        .font(.caption)

      Text(command)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var command: String {
    let executable: String
    if installation.isOnPath {
      executable = "inline"
    } else {
      let escaped = installation.executableURL.path.replacingOccurrences(of: "'", with: "'\\''")
      executable = "'\(escaped)'"
    }
    if issue == .differentAccount {
      return "\(executable) logout\n\(executable) login"
    }
    return "\(executable) login"
  }
}

private struct CLIInstallerSignInMessage: View {
  let issue: CLIInstallerModel.SignInIssue

  var body: some View {
    switch issue {
    case .unsupportedBuild:
      Text("Automatic sign-in is unavailable in this build.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .appNotSignedIn:
      Text("Sign in to Inline for Mac first, or sign in from Terminal.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .differentAccount:
      Text("Inline CLI is signed in to a different account.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case let .authenticationFailed(message):
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .textSelection(.enabled)
    }
  }
}

private struct CLIInstallerFailureContent: View {
  let failure: CLIInstallerFailure

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(failure.title)
        .font(.title2.weight(.semibold))

      ProgressView(value: 0)
        .progressViewStyle(.linear)

      Text(failure.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(4)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CLIInstallerActions: View {
  let model: CLIInstallerModel
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      guideLink

      HStack(spacing: 10) {
        actionButtons
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .buttonStyle(.bordered)
  }

  @ViewBuilder private var actionButtons: some View {
    switch model.phase {
    case .idle:
      Button("Close", action: dismiss)
        .keyboardShortcut(.cancelAction)
      Button("Install") {
        model.start()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    case .installing, .signingIn:
      Button("Cancel") {
        model.cancelOperation()
      }
      .keyboardShortcut(.cancelAction)
    case .ready:
      Button("Done", action: dismiss)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    case .signInNeeded:
      Button("Done", action: dismiss)
        .keyboardShortcut(.cancelAction)
      Button("Try Again") {
        model.start()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    case .failed, .cancelled:
      Button("Close", action: dismiss)
        .keyboardShortcut(.cancelAction)
      Button("Try Again") {
        model.start()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    }
  }

  @ViewBuilder private var guideLink: some View {
    switch model.phase {
    case let .ready(installation, _) where !installation.isOnPath:
      Link("CLI Guide", destination: model.documentationURL)
        .buttonStyle(.link)
    case .signInNeeded:
      Link("CLI Guide", destination: model.documentationURL)
        .buttonStyle(.link)
    case .failed:
      Link("Installation Guide", destination: model.documentationURL)
        .buttonStyle(.link)
    default:
      EmptyView()
    }
  }
}
