#if SPARKLE
import AppKit
import SwiftUI

struct UpdateWindowView: View {
  static let contentSize = CGSize(width: 480, height: 320)

  let controller: UpdateController

  var body: some View {
    UpdateDialogContent(controller: controller)
      .frame(width: Self.contentSize.width, height: Self.contentSize.height)
      .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct UpdateDialogContent: View {
  let controller: UpdateController

  @ViewBuilder
  var body: some View {
    switch controller.phase {
    case .idle:
      UpdateDialogLayout(
        status: .neutral,
        title: "Software Updates"
      ) {
        Text("Inline checks for updates automatically in the background.")
      } details: {
        EmptyView()
      } actions: {
        Spacer()
        Button("Close") {
          controller.dismissStatus()
        }
        .keyboardShortcut(.cancelAction)
      }

    case .checking:
      UpdateDialogLayout(
        status: .working,
        title: "Checking for Updates",
        showsActions: controller.canCancelCurrentOperation
      ) {
        Text("Looking for the latest version of Inline.")
      } details: {
        Text("This usually takes a moment.")
          .font(.callout)
          .foregroundStyle(.tertiary)
      } actions: {
        Spacer()
        Button("Cancel") {
          controller.cancel()
        }
        .keyboardShortcut(.cancelAction)
      }

    case let .updateAvailable(info):
      let title: LocalizedStringResource = info.isInformational
        ? "An Inline Update Is Available"
        : "A New Version Is Available"
      UpdateDialogLayout(
        status: .available,
        title: title
      ) {
        if info.isInformational {
          Text("Learn more about Inline \(info.version) before continuing.")
        } else {
          Text("Inline \(info.version) is ready to download and install.")
        }
      } details: {
        UpdateMetadataView(info: info)
      } actions: {
        Button("Skip This Version") {
          controller.skipVersion()
        }

        Spacer()

        Button("Later") {
          controller.remindLater()
        }
        .keyboardShortcut(.cancelAction)

        if info.isInformational {
          Button("Learn More") {
            controller.beginUpdate()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Update and Relaunch") {
            controller.beginUpdate()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      }

    case let .downloading(_, receivedBytes, expectedBytes):
      UpdateDialogLayout(
        status: .working,
        title: "Downloading Update",
        showsActions: controller.canCancelCurrentOperation
      ) {
        Text("You can keep using Inline while the update downloads.")
      } details: {
        UpdateProgressDetails(
          progress: downloadProgress(receivedBytes: receivedBytes, expectedBytes: expectedBytes),
          receivedBytes: receivedBytes,
          expectedBytes: expectedBytes
        )
      } actions: {
        Spacer()
        Button("Cancel") {
          controller.cancel()
        }
        .keyboardShortcut(.cancelAction)
      }

    case let .extracting(_, progress):
#if DEBUG || DEBUG_BUILD
      let showsActions = controller.isDebugPreviewActive
#else
      let showsActions = false
#endif
      UpdateDialogLayout(
        status: .working,
        title: "Preparing Update",
        showsActions: showsActions
      ) {
        Text("Inline is getting the update ready to install.")
      } details: {
        UpdateProgressDetails(progress: progress)
      } actions: {
#if DEBUG || DEBUG_BUILD
        Spacer()
        Button("Close") {
          controller.dismissStatus()
        }
        .keyboardShortcut(.cancelAction)
#else
        EmptyView()
#endif
      }

    case let .readyToInstall(info):
      UpdateDialogLayout(
        status: .ready,
        title: "Ready to Update"
      ) {
        Text("Inline \(info.version) has been downloaded. Inline will reopen automatically.")
      } details: {
        UpdateMetadataView(info: info)
      } actions: {
        Spacer()

        Button("Later") {
          controller.remindLater()
        }
        .keyboardShortcut(.cancelAction)

        Button("Restart and Update") {
          controller.installAndRelaunch()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }

    case .installing:
      UpdateDialogLayout(
        status: .working,
        title: "Installing Update",
        showsActions: controller.canRetryTermination
      ) {
        Text("Inline will close and reopen when the update is finished.")
      } details: {
        EmptyView()
      } actions: {
        Spacer()
#if DEBUG || DEBUG_BUILD
        if controller.isDebugPreviewActive {
          Button("Close") {
            controller.dismissStatus()
          }
          .keyboardShortcut(.cancelAction)
        } else {
          Button("Try Again") {
            controller.retryTermination()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
#else
        Button("Try Again") {
          controller.retryTermination()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
#endif
      }

    case .upToDate:
      UpdateDialogLayout(
        status: .success,
        title: "Inline Is Up to Date"
      ) {
        Text("You’re using the latest version of Inline.")
      } details: {
        EmptyView()
      } actions: {
        Spacer()
        Button("Done") {
          controller.dismissStatus()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }

    case let .failed(message):
      UpdateDialogLayout(
        status: .failure,
        title: "Couldn’t Check for Updates"
      ) {
        Text(message)
          .textSelection(.enabled)
      } details: {
        EmptyView()
      } actions: {
        Spacer()

        Button("Not Now") {
          controller.dismissStatus()
        }
        .keyboardShortcut(.cancelAction)

        Button("Try Again") {
          controller.retryCheck()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func downloadProgress(receivedBytes: Int64?, expectedBytes: Int64?) -> Double? {
    guard let receivedBytes, let expectedBytes, expectedBytes > 0 else {
      return nil
    }
    return min(1, Double(receivedBytes) / Double(expectedBytes))
  }
}

private struct UpdateDialogLayout<Description: View, Details: View, Actions: View>: View {
  let status: UpdateDialogStatus
  let title: LocalizedStringResource
  let showsActions: Bool
  let description: Description
  let details: Details
  let actions: Actions

  init(
    status: UpdateDialogStatus,
    title: LocalizedStringResource,
    showsActions: Bool = true,
    @ViewBuilder description: () -> Description,
    @ViewBuilder details: () -> Details,
    @ViewBuilder actions: () -> Actions
  ) {
    self.status = status
    self.title = title
    self.showsActions = showsActions
    self.description = description()
    self.details = details()
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 18) {
        UpdateDialogIcon(status: status)
        UpdateDialogHeader(title: title, description: description)
        details
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 32)
      .padding(.top, 28)
      .padding(.bottom, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      if showsActions {
        Divider()

        HStack(spacing: 10) {
          actions
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
    }
  }
}

private struct UpdateDialogHeader<Description: View>: View {
  let title: LocalizedStringResource
  let description: Description

  var body: some View {
    VStack(spacing: 7) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)

      description
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .frame(maxWidth: 380)
    }
  }
}

private struct UpdateDialogIcon: View {
  let status: UpdateDialogStatus

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 72, height: 72)

      ZStack {
        Circle()
          .fill(status.color)

        if status == .working {
          UpdateBadgeSpinner()
        } else {
          Image(systemName: status.symbolName)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 26, height: 26)
      .overlay {
        Circle()
          .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3)
      }
      .offset(x: 2, y: 2)
    }
    .accessibilityHidden(true)
  }
}

private struct UpdateBadgeSpinner: View {
  @State private var isRotating = false

  var body: some View {
    ZStack {
      UpdateBadgeSpinnerTick(angle: 0, opacity: 0.25)
      UpdateBadgeSpinnerTick(angle: 45, opacity: 0.35)
      UpdateBadgeSpinnerTick(angle: 90, opacity: 0.45)
      UpdateBadgeSpinnerTick(angle: 135, opacity: 0.55)
      UpdateBadgeSpinnerTick(angle: 180, opacity: 0.65)
      UpdateBadgeSpinnerTick(angle: 225, opacity: 0.75)
      UpdateBadgeSpinnerTick(angle: 270, opacity: 0.9)
      UpdateBadgeSpinnerTick(angle: 315, opacity: 1)
    }
    .frame(width: 14, height: 14)
    .rotationEffect(.degrees(isRotating ? 360 : 0))
    .animation(
      .linear(duration: 0.8).repeatForever(autoreverses: false),
      value: isRotating
    )
    .onAppear {
      isRotating = true
    }
  }
}

private struct UpdateBadgeSpinnerTick: View {
  let angle: Double
  let opacity: Double

  var body: some View {
    Capsule()
      .fill(.white.opacity(opacity))
      .frame(width: 2, height: 5)
      .offset(y: -4.5)
      .rotationEffect(.degrees(angle))
  }
}

private struct UpdateMetadataView: View {
  let info: SoftwareUpdateInfo

  var body: some View {
    HStack(spacing: 8) {
      Text("Version \(info.version)")

      if let build = info.build, !build.isEmpty, build != info.version {
        Text("Build \(build)")
      }

      if let size = info.contentLength {
        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}

private struct UpdateProgressDetails: View {
  let progress: Double?
  let receivedBytes: Int64?
  let expectedBytes: Int64?

  init(
    progress: Double?,
    receivedBytes: Int64? = nil,
    expectedBytes: Int64? = nil
  ) {
    self.progress = progress
    self.receivedBytes = receivedBytes
    self.expectedBytes = expectedBytes
  }

  var body: some View {
    VStack(spacing: 8) {
      if let progress {
        ProgressView(value: progress)
          .frame(maxWidth: 300)
      } else {
        ProgressView()
          .controlSize(.small)
      }

      if let receivedBytes, let expectedBytes, expectedBytes > 0 {
        Text(
          "\(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file))"
        )
        .font(.callout)
        .foregroundStyle(.tertiary)
      }
    }
  }
}

private enum UpdateDialogStatus: Equatable {
  case neutral
  case working
  case available
  case ready
  case success
  case failure

  var color: Color {
    switch self {
    case .neutral:
      Color(nsColor: .systemGray)
    case .working, .available, .ready:
      Color.accentColor
    case .success:
      Color(nsColor: .systemGreen)
    case .failure:
      Color(nsColor: .systemRed)
    }
  }

  var symbolName: String {
    switch self {
    case .neutral:
      "info"
    case .working:
      "circle"
    case .available:
      "arrow.down"
    case .ready:
      "arrow.clockwise"
    case .success:
      "checkmark"
    case .failure:
      "exclamationmark"
    }
  }
}
#endif
