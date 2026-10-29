import Combine
import GRDB
import InlineKit
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

struct AgentThreadSettingsSection: View {
  @ObservedObject var model: AgentThreadToolbarModel
  let update: (InlineProtocol.AgentThreadContext) async throws -> Void

  var body: some View {
    if model.context != nil {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Thread")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            if let presentation = model.presentation {
              Text(presentation.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if model.isUpdating {
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel("Updating thread settings")
          }
        }

        if let projectTitle = model.projectTitle {
          AgentThreadSettingRow(
            title: "Folder",
            selectionTitle: projectTitle,
            selectionDescription: selectedProjectDescription,
            options: projectOptions,
            selectedID: model.effectiveProjectID,
            automaticTitle: nil,
            isEditable: model.canEditProject,
            isUpdating: model.isUpdating,
            helpText: model.canEditProject
              ? "Changing the folder starts or resumes this chat’s session in that folder."
              : "The folder can change only for chats that aren’t linked to an existing session.",
            select: { id in
              guard let context = model.contextSelectingProject(id) else { return }
              model.performUpdate(context, using: update)
            }
          )
        }

        if let modelTitle = model.modelTitle {
          AgentThreadSettingRow(
            title: "Model",
            selectionTitle: modelTitle,
            selectionDescription: selectedModelDescription,
            options: modelOptions,
            selectedID: model.explicitModelID,
            automaticTitle: model.automaticModelTitle,
            isEditable: model.canEdit,
            isUpdating: model.isUpdating,
            helpText: nil,
            select: selectModel
          )
        }

        if let reasoningTitle = model.reasoningTitle {
          AgentThreadSettingRow(
            title: "Reasoning",
            selectionTitle: reasoningTitle,
            selectionDescription: selectedReasoningDescription,
            options: reasoningOptions,
            selectedID: model.explicitReasoningID,
            automaticTitle: model.automaticReasoningTitle,
            isEditable: model.canEdit,
            isUpdating: model.isUpdating,
            helpText: nil,
            select: selectReasoning
          )
        }

        if model.editabilityResolved, !model.canEdit, showsModel || showsReasoning {
          Label("Only the Agent owner can change these settings.", systemImage: "lock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var showsModel: Bool {
    model.modelTitle != nil
  }

  private var showsReasoning: Bool {
    model.reasoningTitle != nil
  }

  private var projectOptions: [AgentThreadSettingOption] {
    (model.catalog?.projects ?? []).map(AgentThreadSettingOption.init)
  }

  private var modelOptions: [AgentThreadSettingOption] {
    (model.catalog?.models ?? []).map(AgentThreadSettingOption.init)
  }

  private var reasoningOptions: [AgentThreadSettingOption] {
    (model.availableReasoningOptions ?? []).map(AgentThreadSettingOption.init)
  }

  private var selectedProjectDescription: String? {
    projectOptions.first(where: { $0.id == model.effectiveProjectID })?.description
  }

  private var selectedModelDescription: String? {
    modelOptions.first(where: { $0.id == model.effectiveModelID })?.description
  }

  private var selectedReasoningDescription: String? {
    reasoningOptions.first(where: { $0.id == model.effectiveReasoningID })?.description
  }

  private func selectModel(_ id: String?) {
    guard let context = model.contextSelectingModel(id) else { return }
    model.performUpdate(context, using: update)
  }

  private func selectReasoning(_ id: String?) {
    guard let context = model.contextSelectingReasoning(id) else { return }
    model.performUpdate(context, using: update)
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

private struct AgentThreadSettingRow: View {
  let title: LocalizedStringResource
  let selectionTitle: String
  let selectionDescription: String?
  let options: [AgentThreadSettingOption]
  let selectedID: String?
  let automaticTitle: String?
  let isEditable: Bool
  let isUpdating: Bool
  let helpText: LocalizedStringResource?
  let select: (String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 10) {
        Text(title)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)

        if isEditable, automaticTitle != nil || !options.isEmpty {
          Menu {
            if let automaticTitle {
              selectionButton(label: automaticTitle, id: nil)
              if !options.isEmpty { Divider() }
            }
            ForEach(options) { option in
              selectionButton(
                label: option.label,
                description: option.description,
                id: option.id
              )
            }
          } label: {
            selectionValue
          }
          .menuStyle(.borderlessButton)
          .disabled(isUpdating)
          .accessibilityLabel(Text(title))
          .accessibilityValue(selectionTitle)
        } else {
          selectionValue
            .accessibilityLabel(Text(title))
            .accessibilityValue(selectionTitle)
        }
      }
      if let selectionDescription {
        Text(selectionDescription)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      if let helpText {
        Text(helpText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var selectionValue: some View {
    Text(selectionTitle)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: 250, alignment: .trailing)
  }

  private func selectionButton(
    label: String,
    description: String? = nil,
    id: String?
  ) -> some View {
    Button {
      select(id)
    } label: {
      AgentThreadConfigurationOptionLabel(
        title: label,
        description: description,
        isSelected: selectedID == id
      )
    }
  }
}

private struct AgentThreadConfigurationOptionLabel: View {
  let title: String
  let description: String?
  let isSelected: Bool

  var body: some View {
    if isSelected {
      Label {
        content
      } icon: {
        Image(systemName: "checkmark")
      }
    } else {
      content
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
      if let description, !description.isEmpty {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
