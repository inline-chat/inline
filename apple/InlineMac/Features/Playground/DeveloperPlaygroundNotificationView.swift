#if DEBUG || DEBUG_BUILD
import AppKit
import InlineKit
import SwiftUI
import UserNotifications

struct DeveloperPlaygroundNotificationView: View {
  @Environment(\.scenePhase) private var scenePhase

  @State private var senderName = "Ava Lin"
  @State private var message = "Here is the latest project update."
  @State private var isThread = false
  @State private var soundEnabled = false
  @State private var avatarMode = MacNotificationPlaygroundAvatarMode.photo
  @State private var authorizationStatus = UNAuthorizationStatus.notDetermined
  @State private var resultText: String?
  @State private var isScheduling = false
  @State private var inFlightText = "Posting test notification…"
  @State private var isRequestingAuthorization = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        DeveloperPlaygroundNotificationHeader(
          authorizationStatus: authorizationStatus,
          isRequestingAuthorization: isRequestingAuthorization,
          requestAuthorization: {
            Task {
              guard !isRequestingAuthorization else { return }
              isRequestingAuthorization = true
              defer { isRequestingAuthorization = false }
              _ = try? await MacPermissions.requestNotifications()
              await refreshAuthorizationStatus()
            }
          },
          openSettings: {
            MacPermissions.openSystemSettings(.notifications)
          }
        )
        DeveloperPlaygroundNotificationConfiguration(
          senderName: $senderName,
          message: $message,
          isThread: $isThread,
          soundEnabled: $soundEnabled,
          avatarMode: $avatarMode
        )
        .disabled(isScheduling)
        DeveloperPlaygroundNotificationScenarios(
          canTrigger: canTrigger && !isScheduling,
          trigger: { scenario in
            Task { _ = await trigger(scenario) }
          }
        )
        DeveloperPlaygroundNotificationModes(
          canTrigger: canTrigger && !isScheduling,
          trigger: { mode in
            Task { _ = await triggerAvatar(mode) }
          },
          triggerAll: {
            Task { await triggerAllAvatars() }
          }
        )
      }
      .frame(maxWidth: 780, alignment: .topLeading)
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      await refreshAuthorizationStatus()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await refreshAuthorizationStatus() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if isScheduling || resultText != nil {
        VStack(spacing: 0) {
          Divider()
          HStack(spacing: 8) {
            if isScheduling {
              ProgressView()
                .controlSize(.small)
            }
            Text(verbatim: isScheduling ? inFlightText : resultText ?? "")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var canTrigger: Bool {
    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      true
    case .denied, .notDetermined:
      false
    @unknown default:
      false
    }
  }

  @discardableResult
  private func trigger(_ scenario: MacNotificationPlaygroundScenario) async -> Bool {
    guard canTrigger, !isScheduling else { return false }
    inFlightText = "Posting \(scenario.title.lowercased()) test notification…"
    isScheduling = true
    defer { isScheduling = false }

    let didSchedule = await schedule(scenario: scenario, avatarMode: avatarMode)
    setResult(didSchedule
      ? "Requested \(scenario.title.lowercased()) test notification."
      : "The notification request was not accepted.")
    return didSchedule
  }

  @discardableResult
  private func triggerAvatar(_ mode: MacNotificationPlaygroundAvatarMode) async -> Bool {
    guard canTrigger, !isScheduling else { return false }
    inFlightText = "Posting \(mode.title.lowercased()) sender-artwork test…"
    isScheduling = true
    defer { isScheduling = false }

    let didSchedule = await schedule(scenario: .customText, avatarMode: mode)
    setResult(didSchedule
      ? mode.requestedResult
      : "The notification request was not accepted.")
    return didSchedule
  }

  private func triggerAllAvatars() async {
    guard canTrigger, !isScheduling else { return }
    inFlightText = "Posting sender-artwork outcome tests…"
    isScheduling = true
    defer { isScheduling = false }

    var scheduledCount = 0
    for mode in MacNotificationPlaygroundAvatarMode.allCases {
      if await schedule(scenario: .customText, avatarMode: mode) {
        scheduledCount += 1
      }
    }

    let totalCount = MacNotificationPlaygroundAvatarMode.allCases.count
    setResult(scheduledCount == totalCount
      ? "Requested all sender-artwork outcomes. " +
        "Verify portrait and initials attachments, and no attachment for No artwork."
      : "Requested \(scheduledCount) of \(totalCount) sender-artwork outcome tests.")
  }

  private func schedule(
    scenario: MacNotificationPlaygroundScenario,
    avatarMode: MacNotificationPlaygroundAvatarMode
  ) async -> Bool {
    await MacNotifications.shared.showPlaygroundNotification(
      scenario: scenario,
      avatarMode: avatarMode,
      senderName: senderName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Ava Lin",
      customBody: message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Test notification",
      isThread: isThread,
      soundEnabled: soundEnabled
    )
  }

  private func refreshAuthorizationStatus() async {
    authorizationStatus = await MacPermissions.notificationSettings().authorizationStatus
  }

  private func setResult(_ result: String) {
    resultText = result
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: result,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ]
    )
  }
}

private struct DeveloperPlaygroundNotificationHeader: View {
  let authorizationStatus: UNAuthorizationStatus
  let isRequestingAuthorization: Bool
  let requestAuthorization: () -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Notifications")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Trigger real macOS notifications for supported content and delivery states.")
        .foregroundStyle(.secondary)
      Text("System notification settings and Focus still determine whether a request is shown or heard.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Label {
          Text(verbatim: authorizationTitle)
        } icon: {
          Image(systemName: authorizationIconName)
        }
          .foregroundStyle(authorizationColor)

        if authorizationStatus == .notDetermined {
          Button(isRequestingAuthorization ? "Requesting…" : "Allow Notifications", action: requestAuthorization)
            .disabled(isRequestingAuthorization)
        } else if authorizationStatus == .denied {
          Button("Open Settings", action: openSettings)
        }
      }
      .font(.caption)
      .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var authorizationTitle: String {
    switch authorizationStatus {
    case .authorized:
      "Notifications allowed"
    case .provisional:
      "Provisional notification delivery"
    case .ephemeral:
      "Ephemeral notification delivery"
    case .denied:
      "Notifications denied"
    case .notDetermined:
      "Permission not requested"
    @unknown default:
      "Notification permission unknown"
    }
  }

  private var authorizationIconName: String {
    isAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle"
  }

  private var isAuthorized: Bool {
    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      true
    case .denied, .notDetermined:
      false
    @unknown default:
      false
    }
  }

  private var authorizationColor: Color {
    switch authorizationStatus {
    case .authorized:
      .green
    case .provisional, .ephemeral:
      .orange
    case .denied, .notDetermined:
      .secondary
    @unknown default:
      .secondary
    }
  }
}

private struct DeveloperPlaygroundNotificationConfiguration: View {
  @Binding var senderName: String
  @Binding var message: String
  @Binding var isThread: Bool
  @Binding var soundEnabled: Bool
  @Binding var avatarMode: MacNotificationPlaygroundAvatarMode

  var body: some View {
    GroupBox("Presentation") {
      VStack(alignment: .leading, spacing: 4) {
        Form {
          TextField("Sender", text: $senderName)
          TextField("Custom text", text: $message)
          Picker("Sender artwork", selection: $avatarMode) {
            ForEach(MacNotificationPlaygroundAvatarMode.allCases, id: \.self) { mode in
              Text(verbatim: mode.title).tag(mode)
            }
          }
          Toggle("Team chat title/subtitle", isOn: $isThread)
          Toggle("Play sound", isOn: $soundEnabled)
        }
        .formStyle(.columns)
        .padding(8)

        Text("Sender artwork is an independent fixture; team notifications use thread artwork in production.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
      }
    }
  }
}

private struct DeveloperPlaygroundNotificationScenarios: View {
  let canTrigger: Bool
  let trigger: (MacNotificationPlaygroundScenario) -> Void

  private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Notification examples")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text("Text and media examples use the production preview formatter; failed-send is a synthetic fixture.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(MacNotificationPlaygroundScenario.allCases, id: \.self) { scenario in
          DeveloperPlaygroundNotificationScenarioCard(
            scenario: scenario,
            action: { trigger(scenario) }
          )
          .disabled(!canTrigger)
        }
      }
    }
  }
}

private struct DeveloperPlaygroundNotificationScenarioCard: View {
  let scenario: MacNotificationPlaygroundScenario
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: scenario.iconName)
          .font(.title3)
          .foregroundStyle(scenario.tint)
          .frame(width: 32, height: 32)
          .background(scenario.tint.opacity(0.12), in: Circle())
          .accessibilityHidden(true)

        Text(verbatim: scenario.title)
          .font(.subheadline.weight(.medium))
      }

      Text(verbatim: scenario.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

      Button("Show Test", action: action)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(Text(verbatim: "Show \(scenario.title) test notification"))
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
    }
  }
}

private struct DeveloperPlaygroundNotificationModes: View {
  let canTrigger: Bool
  let trigger: (MacNotificationPlaygroundAvatarMode) -> Void
  let triggerAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Sender artwork outcomes")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          Text("These states must not be substituted for one another.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Show All Three", action: triggerAll)
          .disabled(!canTrigger)
          .accessibilityLabel("Show test notifications for all sender artwork outcomes")
      }

      ForEach(MacNotificationPlaygroundAvatarMode.allCases, id: \.self) { mode in
        DeveloperPlaygroundNotificationModeRow(
          mode: mode,
          action: {
            trigger(mode)
          }
        )
        .disabled(!canTrigger)
      }
    }
  }
}

private struct DeveloperPlaygroundNotificationModeRow: View {
  let mode: MacNotificationPlaygroundAvatarMode
  let action: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: mode.iconName)
        .font(.title3)
        .foregroundStyle(mode.tint)
        .frame(width: 32, height: 32)
        .background(mode.tint.opacity(0.12), in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: mode.title)
          .font(.subheadline.weight(.medium))
        Text(verbatim: mode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Show Test", action: action)
        .accessibilityLabel(Text(verbatim: mode.actionAccessibilityLabel))
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
    }
  }
}

private extension MacNotificationPlaygroundAvatarMode {
  var title: String {
    switch self {
    case .photo: "Portrait"
    case .initials: "Initials"
    case .none: "No artwork"
    }
  }

  var detail: String {
    switch self {
    case .photo:
      "A configured and available image attachment (an offline portrait fixture is used)."
    case .initials:
      "No profile photo is configured, so the shared initials style is authoritative."
    case .none:
      "Simulates the production no-attachment outcome without performing a failed download."
    }
  }

  var iconName: String {
    switch self {
    case .photo: "photo.fill"
    case .initials: "person.text.rectangle"
    case .none: "person.crop.circle.badge.xmark"
    }
  }

  var tint: Color {
    switch self {
    case .photo: .blue
    case .initials: .purple
    case .none: .secondary
    }
  }

  var actionAccessibilityLabel: String {
    switch self {
    case .photo: "Show a test notification with portrait sender artwork"
    case .initials: "Show a test notification with initials sender artwork"
    case .none: "Show a test notification with no sender artwork"
    }
  }

  var requestedResult: String {
    switch self {
    case .photo: "Requested the portrait sender-artwork test. Verify the attachment in Notification Center."
    case .initials: "Requested the initials sender-artwork test. Verify the attachment in Notification Center."
    case .none: "Requested the no-sender-artwork test."
    }
  }
}

private extension MacNotificationPlaygroundScenario {
  var title: String {
    switch self {
    case .customText: "Text"
    case .multilineText: "Multiline text"
    case .photo: "Photo fallback"
    case .photoWithCaption: "Photo caption"
    case .video: "Video"
    case .gif: "GIF"
    case .document: "Document"
    case .voice: "Voice message"
    case .sticker: "Sticker"
    case .nudge: "Nudge"
    case .urgentNudge: "Urgent nudge"
    case .messageFailed: "Send failed"
    }
  }

  var detail: String {
    switch self {
    case .customText: "Uses the text entered above; empty input uses “Test notification.”"
    case .multilineText: "Preserves lines and one paragraph break."
    case .photo: "Text fallback without a caption; no message image is attached."
    case .photoWithCaption: "Caption with a preserved line break; no message image is attached."
    case .video: "Text fallback without a caption; no message video is attached."
    case .gif: "Animated-video text fallback rendered as GIF; no message media is attached."
    case .document: "File-name text fallback; no document is attached."
    case .voice: "Duration text fallback (1:05); no audio is attached."
    case .sticker: "Sticker text fallback; no sticker image is attached."
    case .nudge: "Regular nudge using ordinary sound settings."
    case .urgentNudge: "Requests time-sensitive sound even when Play sound is off."
    case .messageFailed: "Failed-send title with safe, non-actionable fixture copy."
    }
  }

  var iconName: String {
    switch self {
    case .customText: "text.bubble"
    case .multilineText: "text.alignleft"
    case .photo: "photo"
    case .photoWithCaption: "photo.badge.plus"
    case .video: "video"
    case .gif: "sparkles.rectangle.stack"
    case .document: "doc"
    case .voice: "waveform"
    case .sticker: "face.smiling"
    case .nudge: "hand.wave"
    case .urgentNudge: "exclamationmark.triangle.fill"
    case .messageFailed: "exclamationmark.bubble"
    }
  }

  var tint: Color {
    switch self {
    case .customText, .multilineText: .blue
    case .photo, .photoWithCaption, .video, .gif: .purple
    case .document, .voice, .sticker: .teal
    case .nudge: .orange
    case .urgentNudge, .messageFailed: .red
    }
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
#endif
