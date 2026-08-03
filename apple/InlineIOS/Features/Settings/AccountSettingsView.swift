import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

struct AccountSessionsSettingsView: View {
  @Environment(\.realtimeV2) private var realtimeV2

  @State private var sessions: [InlineProtocol.AccountSession] = []
  @State private var isLoading = false
  @State private var revokingSessionID: Int64?
  @State private var sessionToRevoke: InlineProtocol.AccountSession?
  @State private var loadError: String?

  var body: some View {
    List {
      Section {
        if isLoading, sessions.isEmpty {
          HStack {
            ProgressView()
            Text("Loading sessions…")
              .foregroundStyle(.secondary)
          }
        } else if let loadError, sessions.isEmpty {
          ContentUnavailableView {
            Label("Could Not Load Sessions", systemImage: "exclamationmark.triangle")
          } description: {
            Text(loadError)
          } actions: {
            Button("Try Again", action: refresh)
          }
        } else if sessions.isEmpty {
          ContentUnavailableView(
            "No Active Sessions",
            systemImage: "laptopcomputer.and.iphone",
            description: Text("No signed-in devices or clients were returned.")
          )
        } else {
          ForEach(sessions, id: \.id) { session in
            AccountSessionRow(
              session: session,
              isRevoking: revokingSessionID == session.id,
              requestRevoke: { sessionToRevoke = session }
            )
          }
        }
      } header: {
        Text("Signed-In Devices")
      } footer: {
        Text("Revoke any device or client you do not recognize. Use Logout below to sign out this device.")
      }

      LogoutSection()
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Active Sessions")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable {
      await loadSessions()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: refresh) {
          Label("Refresh Sessions", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
    }
    .confirmationDialog(
      "Revoke Session?",
      isPresented: Binding(
        get: { sessionToRevoke != nil },
        set: { if !$0 { sessionToRevoke = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Revoke", role: .destructive) {
        guard let session = sessionToRevoke else { return }
        sessionToRevoke = nil
        revoke(session)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This signs that device or client out of your account.")
    }
    .task {
      await loadSessions()
    }
  }

  private func refresh() {
    Task { await loadSessions() }
  }

  private func loadSessions() async {
    guard !isLoading else { return }
    isLoading = true
    loadError = nil
    defer { isLoading = false }

    do {
      sessions = try await realtimeV2.getSessions().sessions
        .sorted { lhs, rhs in
          if lhs.current != rhs.current { return lhs.current }
          return lhs.lastActiveAt > rhs.lastActiveAt
        }
    } catch {
      Log.scoped("IOSSettings.Sessions").error("Failed to load sessions", error: error)
      loadError = error.localizedDescription
      if !sessions.isEmpty {
        ToastManager.shared.showToast(
          "Could not refresh sessions",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func revoke(_ session: InlineProtocol.AccountSession) {
    guard !session.current, revokingSessionID == nil else { return }
    revokingSessionID = session.id

    Task {
      do {
        _ = try await realtimeV2.revokeSession(session.id)
        sessions.removeAll { $0.id == session.id }
      } catch {
        Log.scoped("IOSSettings.Sessions").error("Failed to revoke session", error: error)
        loadError = error.localizedDescription
        ToastManager.shared.showToast(
          "Could not revoke session",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
      revokingSessionID = nil
    }
  }
}

private struct AccountSessionRow: View {
  let session: InlineProtocol.AccountSession
  let isRevoking: Bool
  let requestRevoke: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: iconName)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
            .font(.body)
          if session.current {
            Text("Current")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        if session.lastActiveAt > 0 {
          Text("Last active \(lastActiveDate, format: .relative(presentation: .named))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isRevoking {
        ProgressView()
          .controlSize(.small)
      } else if !session.current {
        Button("Revoke", role: .destructive, action: requestRevoke)
          .buttonStyle(.borderless)
      }
    }
    .padding(.vertical, 3)
  }

  private var title: String {
    optional(session.hasDeviceName, session.deviceName) ?? clientTitle
  }

  private var detail: String {
    [
      clientTitle,
      optional(session.hasClientVersion, session.clientVersion),
      optional(session.hasOsVersion, session.osVersion),
      location,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private var location: String? {
    let parts = [
      optional(session.hasCity, session.city),
      optional(session.hasCountry, session.country),
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  private var clientTitle: String {
    switch session.clientType {
    case "macos": "Inline for Mac"
    case "ios": "Inline for iOS"
    case "web": "Inline Web"
    case "cli": "Inline CLI"
    case "api": "API"
    default: "Unknown Client"
    }
  }

  private var iconName: String {
    switch session.clientType {
    case "macos": "desktopcomputer"
    case "ios": "iphone"
    case "web": "globe"
    case "cli": "terminal"
    default: "person.crop.circle.badge.questionmark"
    }
  }

  private var lastActiveDate: Date {
    Date(timeIntervalSince1970: TimeInterval(session.lastActiveAt))
  }

  private func optional(_ hasValue: Bool, _ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return hasValue && !trimmed.isEmpty ? trimmed : nil
  }
}
