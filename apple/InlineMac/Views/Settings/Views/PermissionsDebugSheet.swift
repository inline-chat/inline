import AVFoundation
import SwiftUI
import UserNotifications

struct PermissionsDebugSheet: View {
  @Environment(\.dismiss) private var dismiss

  @State private var notificationStatus: PermissionStatus = .checking
  @State private var cameraStatus: PermissionStatus = .checking
  @State private var microphoneStatus: PermissionStatus = .checking
  @State private var busyPermission: PermissionKind?

  var body: some View {
    VStack(spacing: 0) {
      header

      Form {
        Section {
          PermissionRow(
            title: "Notifications",
            systemImage: "bell",
            status: notificationStatus,
            isWorking: busyPermission == .notifications,
            checkAction: { check(.notifications) },
            requestAction: { request(.notifications) },
            settingsAction: {
              MacPermissions.openSystemSettings(.notifications)
            }
          )

          PermissionRow(
            title: "Camera",
            systemImage: "camera",
            status: cameraStatus,
            isWorking: busyPermission == .camera,
            checkAction: { check(.camera) },
            requestAction: { request(.camera) },
            settingsAction: {
              MacPermissions.openSystemSettings(.camera)
            }
          )

          PermissionRow(
            title: "Microphone",
            systemImage: "mic",
            status: microphoneStatus,
            isWorking: busyPermission == .microphone,
            checkAction: { check(.microphone) },
            requestAction: { request(.microphone) },
            settingsAction: {
              MacPermissions.openSystemSettings(.microphone)
            }
          )
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
    .frame(width: 480)
    .frame(minHeight: 340)
    .task {
      await refreshAll()
    }
  }

  private var header: some View {
    HStack {
      Text("Permissions")
        .font(.headline)

      Spacer()

      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  @MainActor
  private func check(_ kind: PermissionKind) {
    Task { @MainActor in
      await refresh(kind)
    }
  }

  @MainActor
  private func request(_ kind: PermissionKind) {
    guard busyPermission == nil else { return }
    busyPermission = kind

    Task { @MainActor in
      switch kind {
        case .notifications:
          _ = try? await MacPermissions.requestNotifications()
        case .camera:
          _ = await MacPermissions.requestMediaAccess(for: .video)
        case .microphone:
          _ = await MacPermissions.requestMediaAccess(for: .audio)
      }

      await refresh(kind)
      busyPermission = nil
    }
  }

  @MainActor
  private func refreshAll() async {
    await refresh(.notifications)
    await refresh(.camera)
    await refresh(.microphone)
  }

  @MainActor
  private func refresh(_ kind: PermissionKind) async {
    switch kind {
      case .notifications:
        let settings = await MacPermissions.notificationSettings()
        notificationStatus = PermissionStatus(settings.authorizationStatus)
      case .camera:
        cameraStatus = PermissionStatus(MacPermissions.mediaStatus(for: .video))
      case .microphone:
        microphoneStatus = PermissionStatus(MacPermissions.mediaStatus(for: .audio))
    }
  }
}

private enum PermissionKind {
  case notifications
  case camera
  case microphone
}

private enum PermissionStatus: Equatable {
  case checking
  case notDetermined
  case allowed
  case quiet
  case denied
  case restricted
  case unknown

  init(_ status: UNAuthorizationStatus) {
    switch status {
      case .notDetermined:
        self = .notDetermined
      case .denied:
        self = .denied
      case .authorized:
        self = .allowed
      case .provisional:
        self = .quiet
      default:
        self = .unknown
    }
  }

  init(_ status: AVAuthorizationStatus) {
    switch status {
      case .notDetermined:
        self = .notDetermined
      case .restricted:
        self = .restricted
      case .denied:
        self = .denied
      case .authorized:
        self = .allowed
      @unknown default:
        self = .unknown
    }
  }

  var title: String {
    switch self {
      case .checking:
        "Checking"
      case .notDetermined:
        "Not Asked"
      case .allowed:
        "Allowed"
      case .quiet:
        "Quiet"
      case .denied:
        "Denied"
      case .restricted:
        "Restricted"
      case .unknown:
        "Unknown"
    }
  }

  var tint: Color {
    switch self {
      case .allowed, .quiet:
        .green
      case .notDetermined, .checking:
        .secondary
      case .denied, .restricted:
        .red
      case .unknown:
        .orange
    }
  }

  var canRequest: Bool {
    self == .notDetermined
  }
}

private struct PermissionRow: View {
  let title: String
  let systemImage: String
  let status: PermissionStatus
  let isWorking: Bool
  let checkAction: () -> Void
  let requestAction: () -> Void
  let settingsAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label(title, systemImage: systemImage)

        Spacer()

        Text(status.title)
          .font(.caption)
          .foregroundStyle(status.tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(status.tint.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 8) {
        Button(action: checkAction) {
          Label("Check", systemImage: "arrow.clockwise")
        }
        .help("Check permission")

        Button(action: requestAction) {
          Label(isWorking ? "Requesting" : "Request", systemImage: "hand.raised")
        }
        .disabled(!status.canRequest || isWorking)
        .help("Request permission")

        Button(action: settingsAction) {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open System Settings")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(.vertical, 4)
  }
}

#Preview {
  PermissionsDebugSheet()
}
