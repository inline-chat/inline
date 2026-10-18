import Auth
import RealtimeV2
import SwiftUI

struct ConnectionSecurityDebugSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var realtimeState: RealtimeState
  @ObservedObject private var auth = Auth.shared

  var body: some View {
    VStack(spacing: 0) {
      ConnectionSecurityHeader(dismiss: dismiss)

      Form {
        Section("Current Connection") {
          LabeledContent("Status", value: connectionStatus)
          LabeledContent("Application contract", value: applicationContract)
          LabeledContent("Secure transport", value: secureTransport)
          LabeledContent("Protection", value: protectionStatus)
        }

        Section("Authentication") {
          LabeledContent("Session type", value: sessionType)
          if let authenticatedAt {
            LabeledContent("Authenticated") {
              Text(authenticatedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
          }
          if let temporaryExpiresAt {
            LabeledContent("Temporary authorization expires") {
              Text(temporaryExpiresAt, format: .dateTime.year().month().day().hour().minute().second())
            }
          }
        }

        Section {
          Text(explanation)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
    .frame(width: 520)
    .frame(minHeight: 420)
  }

  private var snapshot: AuthSnapshot {
    auth.handle.snapshot()
  }

  private var connectionStatus: String {
    switch realtimeState.connectionState {
    case .connecting: "Connecting"
    case .updating: "Updating"
    case .connected: "Connected"
    }
  }

  private var applicationContract: String {
    if isUpgradedBearerSession { return "Realtime V3 ready; V2 fallback available" }
    return snapshot.inlineProtocol == nil ? "Realtime V2" : "Realtime V3"
  }

  private var secureTransport: String {
    if isUpgradedBearerSession { return "Depends on the active connection" }
    return snapshot.inlineProtocol == nil ? "Legacy WebSocket" : "Inline Protocol v1"
  }

  private var protectionStatus: String {
    guard snapshot.inlineProtocol != nil else { return "TLS transport security" }
    if isUpgradedBearerSession { return "V3 credentials verified; active protocol not reported here" }
    return switch realtimeState.connectionState {
    case .connected: "Inline Protocol encryption active"
    case .connecting, .updating: "Inline Protocol credentials ready"
    }
  }

  private var sessionType: String {
    if isUpgradedBearerSession { return "Legacy session with verified V3 credentials" }
    return switch snapshot.status {
    case .authenticatedV3: "Native Inline Protocol"
    case .authenticated: "Legacy bearer session"
    case .hydrating: "Loading"
    case .locked: "Credentials locked"
    case .reauthRequired: "Authentication required"
    case .loggingOut: "Logging out"
    case .unauthenticated: "Signed out"
    }
  }

  private var authenticatedAt: Date? {
    if case let .authenticated(credentials) = snapshot.status { return credentials.createdAt }
    if let credentials = snapshot.inlineProtocol { return credentials.createdAt }
    return nil
  }

  private var temporaryExpiresAt: Date? {
    guard let expiresAt = snapshot.inlineProtocol?.temporary?.expiresAt else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(expiresAt))
  }

  private var explanation: String {
    if isUpgradedBearerSession {
      "V3 is ready for the next connection. A working V2 connection continues until it reconnects, and V2 remains available if V3 cannot connect. Saved credentials alone do not identify which protocol is carrying current traffic."
    } else if snapshot.inlineProtocol != nil {
      "Realtime V3 traffic is protected by Inline Protocol above WebSocket and TLS. The permanent authorization key stays in secure local storage; application connections use a bound temporary authorization."
    } else {
      "This account uses Realtime V2 over WebSocket and TLS. V3 preparation happens automatically in the background when available; signing in again is not required."
    }
  }

  private var isUpgradedBearerSession: Bool {
    snapshot.token != nil && snapshot.inlineProtocol != nil
  }
}

private struct ConnectionSecurityHeader: View {
  let dismiss: DismissAction

  var body: some View {
    HStack {
      Text("Connection Security")
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
}

#Preview {
  ConnectionSecurityDebugSheet()
    .environmentObject(RealtimeState())
}
