import InlineKit
import InlineProtocol
@testable import InlineMacUI
import Testing

@Suite("Bot chat settings renderer")
struct BotChatSettingsRendererTests {
  @Test("maps every reusable control", arguments: [
    (BotChatSettingsModel.Control.toggle(value: true), BotChatSettingsControlKind.toggle),
    (.select(value: "auto", options: []), .select),
    (.info(text: "Guide", tone: .neutral), .info),
    (.button, .button),
    (
      .folder(
        value: "workspace-one",
        recentFolders: [],
        hostInstallationID: "host-one",
        hostLabel: "Mo's MacBook Pro",
        allowsLocalPicker: true,
        localPickerPort: 51_234,
        localPickerCapability: "capability-0123456789abcdef0123456789abcdef"
      ),
      .folder
    ),
  ])
  func mapsControl(control: BotChatSettingsModel.Control, expected: BotChatSettingsControlKind) {
    #expect(botChatSettingsControlKind(for: control) == expected)
  }

  @Test("collapses repeated disabled reasons into one access note")
  func sharedDisabledReason() throws {
    let reason = "Only an authorized controller can change this."
    let protocolDocument = InlineProtocol.BotChatSettingsDocument.with {
      $0.version = 1
      $0.revision = "test"
      $0.sections = [.with {
        $0.id = "runtime"
        $0.items = ["model", "reasoning"].map { id in
          .with {
            $0.id = id
            $0.label = id.capitalized
            $0.disabled = true
            $0.disabledReason = reason
            $0.control = .select(.with {
              $0.value = id
              $0.options = [.with {
                $0.value = id
                $0.label = id.capitalized
              }]
            })
          }
        }
      }]
    }
    let document = try BotChatSettingsModel.Document(protocolDocument: protocolDocument)

    #expect(botChatSettingsSharedDisabledReason(in: document) == reason)
  }

  @Test("preserves distinct disabled reasons for their controls")
  func distinctDisabledReasons() throws {
    let protocolDocument = InlineProtocol.BotChatSettingsDocument.with {
      $0.version = 1
      $0.revision = "test"
      $0.sections = [.with {
        $0.id = "runtime"
        $0.items = ["Model access", "Thread access"].enumerated().map { index, reason in
          .with {
            $0.id = "item-\(index)"
            $0.label = "Item \(index)"
            $0.disabled = true
            $0.disabledReason = reason
            $0.control = .toggle(.init())
          }
        }
      }]
    }
    let document = try BotChatSettingsModel.Document(protocolDocument: protocolDocument)

    #expect(botChatSettingsSharedDisabledReason(in: document) == nil)
  }

  @Test("local folder picker receives the exact host and bot identity")
  @MainActor
  func localFolderPickerIdentity() async throws {
    var receivedHost: String?
    var receivedBotID: Int64?
    let picker: BotChatSettingsLocalFolderPicker = { hostInstallationID, botUserID, port, capability in
      receivedHost = hostInstallationID
      receivedBotID = botUserID
      #expect(port == 51_234)
      #expect(capability.hasPrefix("capability-"))
      return "workspace-opaque"
    }

    let workspaceID = try await picker("host-123", 42, 51_234, "capability-0123456789abcdef0123456789abcdef")
    #expect(workspaceID == "workspace-opaque")
    #expect(receivedHost == "host-123")
    #expect(receivedBotID == 42)
  }

  @Test("local picker availability is host-scoped")
  @MainActor
  func localFolderPickerAvailability() async {
    let availability: BotChatSettingsLocalPickerAvailability = { hostInstallationID, botUserID, port, capability in
      hostInstallationID == "this-mac" && botUserID == 42 && port == 51_234 && capability == "capability"
    }
    #expect(await availability("this-mac", 42, 51_234, "capability"))
    #expect(!(await availability("other-mac", 42, 51_234, "capability")))
  }

  @Test("a stale picker probe cannot authorize a replacement endpoint")
  func staleLocalPickerProbe() {
    var state = BotChatSettingsLocalPickerProbeState()

    state.begin("endpoint-a")
    state.complete("endpoint-a", isReachable: true)
    #expect(state.isReachable)

    state.begin("endpoint-b")
    #expect(!state.isReachable)
    state.complete("endpoint-a", isReachable: true)
    #expect(!state.isReachable)

    state.complete("endpoint-b", isReachable: true)
    #expect(state.isReachable)
  }
}
