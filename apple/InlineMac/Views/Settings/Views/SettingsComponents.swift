import SwiftUI

struct SettingsRowLabel: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource?
  private let dynamicDescription: String?

  init(
    _ title: LocalizedStringResource,
    description: LocalizedStringResource? = nil
  ) {
    self.title = title
    self.description = description
    dynamicDescription = nil
  }

  init(
    _ title: LocalizedStringResource,
    dynamicDescription: String
  ) {
    self.title = title
    description = nil
    self.dynamicDescription = dynamicDescription
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)

      if let description {
        Text(description)
          .settingsDescriptionStyle()
      } else if let dynamicDescription {
        Text(dynamicDescription)
          .settingsDescriptionStyle()
      }
    }
  }
}

struct SettingsSectionHeader: View {
  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource?

  init(
    _ title: LocalizedStringResource,
    subtitle: LocalizedStringResource? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.headline)

      if let subtitle {
        Text(subtitle)
          .settingsDescriptionStyle()
      }
    }
  }
}

struct SettingsLoadingRow: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource?

  init(
    _ title: LocalizedStringResource,
    description: LocalizedStringResource? = nil
  ) {
    self.title = title
    self.description = description
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      ProgressView()
        .controlSize(.small)

      SettingsRowLabel(title, description: description)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
  }
}

struct SettingsEmptyRow: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource?
  let systemImage: String

  init(
    _ title: LocalizedStringResource,
    description: LocalizedStringResource? = nil,
    systemImage: String = "tray"
  ) {
    self.title = title
    self.description = description
    self.systemImage = systemImage
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)

      SettingsRowLabel(title, description: description)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
  }
}

struct SettingsErrorRow: View {
  private let title: Text
  let message: String?
  let actionTitle: LocalizedStringResource?
  let action: (() -> Void)?

  init(
    _ title: LocalizedStringResource,
    message: String? = nil,
    actionTitle: LocalizedStringResource? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = Text(title)
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  init(
    dynamicTitle: String,
    message: String? = nil,
    actionTitle: LocalizedStringResource? = nil,
    action: (() -> Void)? = nil
  ) {
    title = Text(dynamicTitle)
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .frame(width: 18)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        title

        if let message, !message.isEmpty {
          Text(message)
            .settingsDescriptionStyle()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let actionTitle, let action {
        Button {
          action()
        } label: {
          Text(actionTitle)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct SettingsDetailText: View {
  let text: String

  var body: some View {
    Text(text)
      .settingsDescriptionStyle()
  }
}

struct SettingsEditSheet<Content: View>: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let isSaving: Bool
  let canSave: Bool
  let onCancel: () -> Void
  let onSave: () -> Void
  let content: Content

  init(
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    isSaving: Bool,
    canSave: Bool,
    onCancel: @escaping () -> Void,
    onSave: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    self.isSaving = isSaving
    self.canSave = canSave
    self.onCancel = onCancel
    self.onSave = onSave
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)

        Text(detail)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)

      Divider()

      content
        .settingsFormStyle()

      Divider()

      HStack(spacing: 8) {
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)

        Button {
          onSave()
        } label: {
          if isSaving {
            Text("Saving...")
          } else {
            Text("Save")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || !canSave)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(16)
    }
  }
}

private struct SettingsFormStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}

private struct SettingsDescriptionStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

extension View {
  func settingsFormStyle() -> some View {
    modifier(SettingsFormStyleModifier())
  }

  fileprivate func settingsDescriptionStyle() -> some View {
    modifier(SettingsDescriptionStyleModifier())
  }
}
