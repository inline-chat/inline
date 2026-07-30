@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Bot chat settings models")
struct BotChatSettingsModelsTests {
  @Test("maps every V1 control")
  func mapsControls() throws {
    let document = try BotChatSettingsModel.Document(protocolDocument: makeDocument())
    let controls = document.sections.flatMap(\.items).map(\.control)

    #expect(controls == [
      .toggle(value: true),
      .select(value: "auto", options: [.init(
        value: "auto",
        label: "Auto",
        description: "Agent decides.",
        isDisabled: false
      )]),
      .info(text: "Short guide.", tone: .neutral),
      .button,
      .folder(
        value: "workspace-one",
        recentFolders: [
          .init(
            value: "workspace-one",
            label: "inline",
            parentHint: "inline-chat",
            isDisabled: false
          ),
          .init(
            value: "workspace-two",
            label: "bookmark",
            parentHint: "dev",
            isDisabled: false
          ),
        ],
        hostInstallationID: "host-one",
        hostLabel: "Mo's MacBook Pro",
        allowsLocalPicker: true,
        localPickerPort: 51_234,
        localPickerCapability: "capability-0123456789abcdef0123456789abcdef"
      ),
    ])
  }

  @Test("rejects duplicate item identifiers across sections")
  func rejectsDuplicateItems() {
    var document = makeDocument()
    document.sections.append(.with {
      $0.id = "second"
      $0.items = [.with {
        $0.id = "following"
        $0.label = "Duplicate"
        $0.control = .button(.init())
      }]
    })

    #expect(throws: BotChatSettingsModelError.duplicateItemIdentifier("following")) {
      try BotChatSettingsModel.Document(protocolDocument: document)
    }
  }

  @Test("applies valid optimistic values without changing the revision")
  func optimisticMutation() throws {
    let document = try BotChatSettingsModel.Document(protocolDocument: makeDocument())

    let toggled = document.applyingOptimisticMutation(itemID: "following", value: .bool(false))
    let selected = toggled?.applyingOptimisticMutation(itemID: "reply-threads", value: .string("auto"))
    let workspace = selected?.applyingOptimisticMutation(itemID: "workspace", value: .string("workspace-two"))

    #expect(workspace?.revision == "revision-one")
    #expect(workspace?.sections.flatMap(\.items).first(where: { $0.id == "following" })?.control == .toggle(value: false))
    #expect(workspace?.sections.flatMap(\.items).first(where: { $0.id == "reply-threads" })?.control == .select(
      value: "auto",
      options: [.init(value: "auto", label: "Auto", description: "Agent decides.", isDisabled: false)]
    ))
    #expect(workspace?.sections.flatMap(\.items).first(where: { $0.id == "workspace" })?.control == .folder(
      value: "workspace-two",
      recentFolders: [
        .init(value: "workspace-one", label: "inline", parentHint: "inline-chat", isDisabled: false),
        .init(value: "workspace-two", label: "bookmark", parentHint: "dev", isDisabled: false),
      ],
      hostInstallationID: "host-one",
      hostLabel: "Mo's MacBook Pro",
      allowsLocalPicker: true,
      localPickerPort: 51_234,
      localPickerCapability: "capability-0123456789abcdef0123456789abcdef"
    ))
  }

  @Test("rejects invalid optimistic values")
  func rejectsInvalidOptimisticMutation() throws {
    let document = try BotChatSettingsModel.Document(protocolDocument: makeDocument())

    #expect(document.applyingOptimisticMutation(itemID: "missing", value: .bool(true)) == nil)
    #expect(document.applyingOptimisticMutation(itemID: "following", value: .string("on")) == nil)
    #expect(document.applyingOptimisticMutation(itemID: "reply-threads", value: .string("missing")) == nil)
    #expect(document.applyingOptimisticMutation(itemID: "workspace", value: .string("missing")) == nil)
  }

  @Test("folder presentation preserves ordered opaque recents and host fallback")
  func folderPresentation() throws {
    let document = try BotChatSettingsModel.Document(protocolDocument: makeDocument())
    let control = try #require(document.sections.flatMap(\.items).first(where: { $0.id == "workspace" })?.control)
    let presentation = try #require(control.folderPresentation)

    #expect(presentation.selectedFolder.value == "workspace-one")
    #expect(presentation.recentFolders.map(\.value) == ["workspace-one", "workspace-two"])
    #expect(presentation.hostInstallationID == "host-one")
    #expect(presentation.hostLabel == "Mo's MacBook Pro")
    #expect(presentation.localPickerPort == 51_234)
    #expect(presentation.pickerTitle == "Pick a Folder…")
    #expect(presentation.remotePickerMessage == "Add the folder on Mo's MacBook Pro, then it will appear here.")
    #expect(presentation.commandFallback == "inline bridge workspace add PATH")
  }

  @Test("keeps known controls when a future control is unavailable")
  func skipsUnknownControls() throws {
    var protocolDocument = makeDocument()
    protocolDocument.sections[0].items.append(.with { $0.id = "future-control" })

    let document = try BotChatSettingsModel.Document(protocolDocument: protocolDocument)

    #expect(document.sections[0].items.count == 5)
  }
}

private func makeDocument() -> InlineProtocol.BotChatSettingsDocument {
  .with {
    $0.version = 1
    $0.revision = "revision-one"
    $0.sections = [.with {
      $0.id = "essentials"
      $0.items = [
        .with {
          $0.id = "following"
          $0.label = "Following"
          $0.control = .toggle(.with { $0.value = true })
        },
        .with {
          $0.id = "reply-threads"
          $0.label = "Reply in threads"
          $0.control = .select(.with {
            $0.value = "auto"
            $0.options = [.with {
              $0.value = "auto"
              $0.label = "Auto"
              $0.description_p = "Agent decides."
            }]
          })
        },
        .with {
          $0.id = "guide"
          $0.control = .info(.with {
            $0.text = "Short guide."
            $0.tone = .unspecified
          })
        },
        .with {
          $0.id = "default"
          $0.label = "Use as default"
          $0.control = .button(.init())
        },
        .with {
          $0.id = "workspace"
          $0.label = "Folder"
          $0.control = .folder(.with {
            $0.value = "workspace-one"
            $0.recentFolders = [
              .with {
                $0.value = "workspace-one"
                $0.label = "inline"
                $0.parentHint = "inline-chat"
              },
              .with {
                $0.value = "workspace-two"
                $0.label = "bookmark"
                $0.parentHint = "dev"
              },
            ]
            $0.hostInstallationID = "host-one"
            $0.hostLabel = "Mo's MacBook Pro"
            $0.allowsLocalPicker = true
            $0.localPickerPort = 51_234
            $0.localPickerCapability = "capability-0123456789abcdef0123456789abcdef"
          })
        },
      ]
    }]
  }
}
