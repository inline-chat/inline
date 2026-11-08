import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineProtocol
import InlineUI
import SwiftUI

struct AgentThreadToolbarIndicator: View {
  @ObservedObject var model: AgentThreadToolbarModel

  var body: some View {
    if let presentation = model.presentation {
      HStack(spacing: 4) {
        UserAvatar(userInfo: presentation.userInfo, size: 14)
        Text(presentation.name)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: 120, alignment: .leading)
      // Preserve the ideal width; maxWidth remains only a truncation cap.
      .fixedSize(horizontal: true, vertical: true)
      .help(tooltip(presentation))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Agent session: \(presentation.name)")
      .accessibilityHint("Open Agent Settings to change this thread’s configuration.")
    }
  }

  private func tooltip(_ presentation: AgentThreadToolbarPresentation) -> String {
    let owner = presentation.name == presentation.botName
      ? presentation.name
      : "\(presentation.name) via \(presentation.botName)"
    return "Bound to \(owner). This thread has its own Agent session."
  }
}


/// An agent thread's own folder, model and reasoning, as rows in Agent
/// Settings. The provider's copies of these stay hidden (`hiddenItemIDs`).
struct AgentThreadSettingsRows: View {
  @ObservedObject var model: AgentThreadToolbarModel
  let update: (InlineProtocol.AgentThreadContext) async throws -> Void

  /// Provider items these rows already show.
  static func hiddenItemIDs(for model: AgentThreadToolbarModel) -> Set<String> {
    guard model.context != nil else { return [] }
    var ids = Set<String>()
    if model.projectTitle != nil {
      ids.formUnion([ComposeAgentSettingsItem.folder, ComposeAgentSettingsItem.project])
    }
    if model.modelTitle != nil { ids.insert(ComposeAgentSettingsItem.model) }
    if model.reasoningTitle != nil { ids.insert(ComposeAgentSettingsItem.reasoning) }
    return ids
  }

  /// The thread's rows are read-only for this viewer.
  static func isLocked(_ model: AgentThreadToolbarModel) -> Bool {
    model.context != nil && model.editabilityResolved && !model.canEdit &&
      (model.modelTitle != nil || model.reasoningTitle != nil)
  }

  var body: some View {
    if model.context != nil {
      if let projectTitle = model.projectTitle {
        row(
          "Folder",
          value: projectTitle,
          options: (model.catalog?.projects ?? []).map(AgentThreadSettingOption.init),
          selectedID: model.effectiveProjectID,
          automaticTitle: nil,
          isEditable: model.canEditProject,
          help: model.canEditProject
            ? "Changing the folder starts or resumes this chat’s session in that folder."
            : "The folder can change only for chats that aren’t linked to an existing session."
        ) { id in
          guard let context = model.contextSelectingProject(id) else { return }
          model.performUpdate(context, using: update)
        }
      }

      if let modelTitle = model.modelTitle {
        row(
          "Model",
          value: modelTitle,
          options: (model.catalog?.models ?? []).map(AgentThreadSettingOption.init),
          selectedID: model.explicitModelID,
          automaticTitle: model.automaticModelTitle,
          isEditable: model.canEdit,
          help: nil
        ) { id in
          guard let context = model.contextSelectingModel(id) else { return }
          model.performUpdate(context, using: update)
        }
      }

      if let reasoningTitle = model.reasoningTitle {
        row(
          "Reasoning",
          value: reasoningTitle,
          options: (model.availableReasoningOptions ?? []).map(AgentThreadSettingOption.init),
          selectedID: model.explicitReasoningID,
          automaticTitle: model.automaticReasoningTitle,
          isEditable: model.canEdit,
          help: nil
        ) { id in
          guard let context = model.contextSelectingReasoning(id) else { return }
          model.performUpdate(context, using: update)
        }
      }
    }
  }

  private func row(
    _ title: String,
    value: String,
    options: [AgentThreadSettingOption],
    selectedID: String?,
    automaticTitle: String?,
    isEditable: Bool,
    help: String?,
    select: @escaping (String?) -> Void
  ) -> some View {
    let selected = options.first(where: { $0.id == selectedID })
    return AgentSettingsRow(title) {
      AgentSettingsMenu(
        value,
        accessibilityLabel: title,
        isEditable: isEditable && (automaticTitle != nil || !options.isEmpty)
      ) {
        if let automaticTitle {
          AgentSettingsMenuItem(automaticTitle, isSelected: selectedID == nil) { select(nil) }
          if !options.isEmpty { Divider() }
        }
        ForEach(options) { option in
          AgentSettingsMenuItem(
            option.label,
            description: option.description,
            isSelected: option.id == selectedID
          ) {
            select(option.id)
          }
        }
      }
      .disabled(model.isUpdating)
    }
    .help(help ?? selected?.description ?? "")
  }
}

private struct AgentThreadSettingOption: Identifiable, Equatable {
  let id: String
  let label: String
  let description: String?

  init(_ option: AgentConfigurationOption) {
    id = option.id
    label = option.label
    description = option.description
  }

  init(_ option: AgentModelConfigurationOption) {
    id = option.id
    label = option.label
    description = option.description
  }
}
