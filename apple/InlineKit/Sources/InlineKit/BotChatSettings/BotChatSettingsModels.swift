import Foundation
import InlineProtocol

public enum BotChatSettingsLimits {
  public static let sections = 100
  public static let items = 100
  public static let selectOptions = 100
  public static let folderOptions = 8
}

public enum BotChatSettingsModel {
  public struct Document: Equatable, Sendable {
    public let version: UInt32
    public let revision: String
    public let sections: [Section]
  }

  public struct Section: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let description: String?
    public let items: [Item]
  }

  public struct Item: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String?
    public let description: String?
    public let isDisabled: Bool
    public let disabledReason: String?
    public let control: Control
  }

  public enum Control: Equatable, Sendable {
    case toggle(value: Bool)
    case select(value: String, options: [SelectOption])
    case info(text: String, tone: InfoTone)
    case button
    case folder(
      value: String,
      recentFolders: [FolderOption],
      hostInstallationID: String,
      hostLabel: String,
      allowsLocalPicker: Bool,
      localPickerPort: UInt16?,
      localPickerCapability: String?
    )
  }

  public struct SelectOption: Identifiable, Equatable, Sendable {
    public var id: String { value }
    public let value: String
    public let label: String
    public let description: String?
    public let isDisabled: Bool
  }

  public struct FolderOption: Identifiable, Equatable, Sendable {
    public var id: String { value }
    public let value: String
    public let label: String
    public let parentHint: String?
    public let isDisabled: Bool
  }

  public struct FolderPresentation: Equatable, Sendable {
    public let selectedFolder: FolderOption
    public let recentFolders: [FolderOption]
    public let hostInstallationID: String
    public let hostLabel: String
    public let allowsLocalPicker: Bool
    public let localPickerPort: UInt16?
    public let localPickerCapability: String?
    public let pickerTitle = "Pick a Folder…"

    public var remotePickerMessage: String {
      "Add the folder on \(hostLabel), then it will appear here."
    }

    public let commandFallback = "inline bridge workspace add PATH"
  }

  public enum InfoTone: Equatable, Sendable {
    case neutral
    case success
    case warning
    case error
  }
}

public extension BotChatSettingsModel.Control {
  var folderPresentation: BotChatSettingsModel.FolderPresentation? {
    guard case let .folder(
      value,
      recentFolders,
      hostInstallationID,
      hostLabel,
      allowsLocalPicker,
      localPickerPort,
      localPickerCapability
    ) = self,
          let selectedFolder = recentFolders.first(where: { $0.value == value })
    else { return nil }
    return .init(
      selectedFolder: selectedFolder,
      recentFolders: recentFolders,
      hostInstallationID: hostInstallationID,
      hostLabel: hostLabel,
      allowsLocalPicker: allowsLocalPicker,
      localPickerPort: localPickerPort,
      localPickerCapability: localPickerCapability
    )
  }
}

public enum BotChatSettingsMutationValue: Equatable, Sendable {
  case bool(Bool)
  case string(String)

  public var protocolValue: InlineProtocol.BotChatSettingsValue {
    .with { value in
      switch self {
      case let .bool(bool): value.value = .boolValue(bool)
      case let .string(string): value.value = .stringValue(string)
      }
    }
  }
}

public enum BotChatSettingsModelError: Error, Equatable, Sendable {
  case unsupportedVersion(UInt32)
  case tooManySections
  case tooManyItems
  case tooManyOptions
  case invalidIdentifier
  case duplicateSectionIdentifier(String)
  case duplicateItemIdentifier(String)
  case duplicateOptionValue(String)
  case invalidSelectValue(String)
  case invalidFolderValue(String)
  case invalidFolderMetadata
  case missingLabel(String)
  case missingControl(String)
  case unsupportedInfoTone
}

public extension BotChatSettingsModel.Document {
  init(protocolDocument: InlineProtocol.BotChatSettingsDocument) throws {
    guard protocolDocument.version == 1 else {
      throw BotChatSettingsModelError.unsupportedVersion(protocolDocument.version)
    }
    guard protocolDocument.sections.count <= BotChatSettingsLimits.sections else {
      throw BotChatSettingsModelError.tooManySections
    }
    guard Self.isValidIdentifier(protocolDocument.revision) else {
      throw BotChatSettingsModelError.invalidIdentifier
    }

    var sectionIDs = Set<String>()
    var itemIDs = Set<String>()
    var totalItems = 0
    var parsedSections: [BotChatSettingsModel.Section] = []

    for section in protocolDocument.sections {
      guard Self.isValidIdentifier(section.id) else { throw BotChatSettingsModelError.invalidIdentifier }
      guard sectionIDs.insert(section.id).inserted else {
        throw BotChatSettingsModelError.duplicateSectionIdentifier(section.id)
      }
      totalItems += section.items.count
      guard totalItems <= BotChatSettingsLimits.items else { throw BotChatSettingsModelError.tooManyItems }

      var parsedItems: [BotChatSettingsModel.Item] = []
      for item in section.items {
        guard Self.isValidIdentifier(item.id) else { throw BotChatSettingsModelError.invalidIdentifier }
        guard itemIDs.insert(item.id).inserted else {
          throw BotChatSettingsModelError.duplicateItemIdentifier(item.id)
        }
        if let parsedItem = try Self.parse(item) {
          parsedItems.append(parsedItem)
        }
      }
      parsedSections.append(.init(
        id: section.id,
        title: section.hasTitle ? section.title.nilIfEmpty : nil,
        description: section.hasDescription_p ? section.description_p.nilIfEmpty : nil,
        items: parsedItems
      ))
    }

    self.init(version: protocolDocument.version, revision: protocolDocument.revision, sections: parsedSections)
  }

  private static func parse(_ item: InlineProtocol.BotChatSettingsItem) throws -> BotChatSettingsModel.Item? {
    let label = item.hasLabel ? item.label.nilIfEmpty : nil
    let control: BotChatSettingsModel.Control
    switch item.control {
    case let .toggle(toggle):
      guard label != nil else { throw BotChatSettingsModelError.missingLabel(item.id) }
      control = .toggle(value: toggle.value)
    case let .select(select):
      guard label != nil else { throw BotChatSettingsModelError.missingLabel(item.id) }
      guard !select.options.isEmpty, select.options.count <= BotChatSettingsLimits.selectOptions else {
        throw BotChatSettingsModelError.tooManyOptions
      }
      var values = Set<String>()
      let options = try select.options.map { option in
        guard isValidIdentifier(option.value), isValidLabel(option.label) else {
          throw BotChatSettingsModelError.invalidIdentifier
        }
        guard values.insert(option.value).inserted else {
          throw BotChatSettingsModelError.duplicateOptionValue(option.value)
        }
        return BotChatSettingsModel.SelectOption(
          value: option.value,
          label: option.label,
          description: option.hasDescription_p ? option.description_p.nilIfEmpty : nil,
          isDisabled: option.disabled
        )
      }
      guard options.contains(where: { $0.value == select.value }) else {
        throw BotChatSettingsModelError.invalidSelectValue(select.value)
      }
      control = .select(value: select.value, options: options)
    case let .info(info):
      let tone: BotChatSettingsModel.InfoTone = switch info.tone {
      case .unspecified, .neutral: .neutral
      case .success: .success
      case .warning: .warning
      case .error: .error
      case .UNRECOGNIZED: throw BotChatSettingsModelError.unsupportedInfoTone
      }
      control = .info(text: info.text, tone: tone)
    case .button:
      guard label != nil else { throw BotChatSettingsModelError.missingLabel(item.id) }
      control = .button
    case let .folder(folder):
      guard label != nil else { throw BotChatSettingsModelError.missingLabel(item.id) }
      guard !folder.recentFolders.isEmpty, folder.recentFolders.count <= BotChatSettingsLimits.folderOptions else {
        throw BotChatSettingsModelError.tooManyOptions
      }
      guard isOpaqueIdentifier(folder.hostInstallationID), isDisplayComponent(folder.hostLabel) else {
        throw BotChatSettingsModelError.invalidFolderMetadata
      }
      let hasPickerEndpoint = folder.hasLocalPickerPort || folder.hasLocalPickerCapability
      guard folder.allowsLocalPicker == hasPickerEndpoint else {
        throw BotChatSettingsModelError.invalidFolderMetadata
      }
      let localPickerPort: UInt16?
      let localPickerCapability: String?
      if hasPickerEndpoint {
        guard folder.localPickerPort >= 1_024, folder.localPickerPort <= UInt32(UInt16.max),
              isOpaqueIdentifier(folder.localPickerCapability)
        else {
          throw BotChatSettingsModelError.invalidFolderMetadata
        }
        localPickerPort = UInt16(folder.localPickerPort)
        localPickerCapability = folder.localPickerCapability
      } else {
        localPickerPort = nil
        localPickerCapability = nil
      }
      var values = Set<String>()
      let recentFolders = try folder.recentFolders.map { option in
        guard isOpaqueIdentifier(option.value), isDisplayComponent(option.label),
              !option.hasParentHint || isDisplayComponent(option.parentHint)
        else {
          throw BotChatSettingsModelError.invalidFolderMetadata
        }
        guard values.insert(option.value).inserted else {
          throw BotChatSettingsModelError.duplicateOptionValue(option.value)
        }
        return BotChatSettingsModel.FolderOption(
          value: option.value,
          label: option.label,
          parentHint: option.hasParentHint ? option.parentHint.nilIfEmpty : nil,
          isDisabled: option.disabled
        )
      }
      guard recentFolders.contains(where: { $0.value == folder.value }) else {
        throw BotChatSettingsModelError.invalidFolderValue(folder.value)
      }
      control = .folder(
        value: folder.value,
        recentFolders: recentFolders,
        hostInstallationID: folder.hostInstallationID,
        hostLabel: folder.hostLabel,
        allowsLocalPicker: folder.allowsLocalPicker,
        localPickerPort: localPickerPort,
        localPickerCapability: localPickerCapability
      )
    case nil:
      // Unknown future oneof fields decode as nil. Keep the rest of the
      // settings document usable when a newer bot adds a control.
      return nil
    }
    return .init(
      id: item.id,
      label: label,
      description: item.hasDescription_p ? item.description_p.nilIfEmpty : nil,
      isDisabled: item.disabled,
      disabledReason: item.hasDisabledReason ? item.disabledReason.nilIfEmpty : nil,
      control: control
    )
  }

  private static func isValidIdentifier(_ value: String) -> Bool { value.nilIfEmpty != nil }
  private static func isValidLabel(_ value: String) -> Bool { value.nilIfEmpty != nil }
  private static func isOpaqueIdentifier(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
  }
  private static func isDisplayComponent(_ value: String) -> Bool {
    guard value.nilIfEmpty != nil else { return false }
    return value.rangeOfCharacter(from: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))) == nil
  }

  func applyingOptimisticMutation(
    itemID: String,
    value: BotChatSettingsMutationValue?
  ) -> BotChatSettingsModel.Document? {
    var foundItem = false
    var validMutation = false
    let nextSections = sections.map { section in
      let nextItems = section.items.map { item in
        guard item.id == itemID else { return item }
        foundItem = true
        guard !item.isDisabled else { return item }

        let nextControl: BotChatSettingsModel.Control
        switch (item.control, value) {
        case let (.toggle, .bool(nextValue)):
          nextControl = .toggle(value: nextValue)
        case let (.select(_, options), .string(nextValue))
          where options.contains(where: { $0.value == nextValue && !$0.isDisabled }):
          nextControl = .select(value: nextValue, options: options)
        case (.button, nil):
          nextControl = .button
        case let (.folder(
          _,
          recentFolders,
          hostInstallationID,
          hostLabel,
          allowsLocalPicker,
          localPickerPort,
          localPickerCapability
        ), .string(nextValue))
          where recentFolders.contains(where: { $0.value == nextValue && !$0.isDisabled }):
          nextControl = .folder(
            value: nextValue,
            recentFolders: recentFolders,
            hostInstallationID: hostInstallationID,
            hostLabel: hostLabel,
            allowsLocalPicker: allowsLocalPicker,
            localPickerPort: localPickerPort,
            localPickerCapability: localPickerCapability
          )
        default:
          return item
        }
        validMutation = true
        return .init(
          id: item.id,
          label: item.label,
          description: item.description,
          isDisabled: item.isDisabled,
          disabledReason: item.disabledReason,
          control: nextControl
        )
      }
      return BotChatSettingsModel.Section(
        id: section.id,
        title: section.title,
        description: section.description,
        items: nextItems
      )
    }
    guard foundItem, validMutation else { return nil }
    return .init(version: version, revision: revision, sections: nextSections)
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
