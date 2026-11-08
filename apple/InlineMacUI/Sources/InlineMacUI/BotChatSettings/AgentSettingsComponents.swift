import SwiftUI

/// The pieces Agent Settings is built from, so the chat's own choices, the
/// provider's settings and usage all read as one popover.
public enum AgentSettingsMetrics {
  public static let width: CGFloat = 340
  public static let maxHeight: CGFloat = 540
  static let rowHeight: CGFloat = 28
  static let groupSpacing: CGFloat = 14
  static let contentPadding: CGFloat = 12
}

/// An inset group with an optional small title above it.
public struct AgentSettingsGroup<Content: View>: View {
  private let title: String?
  private let content: Content

  public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let title {
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.leading, 2)
          .accessibilityAddTraits(.isHeader)
      }
      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }
}

/// A title on the leading edge and its control on the trailing edge, with an
/// optional note under it for what the control can't say on its own.
public struct AgentSettingsRow<Accessory: View>: View {
  private let title: String
  private let note: String?
  private let isPending: Bool
  private let accessory: Accessory

  public init(
    _ title: String,
    note: String? = nil,
    isPending: Bool = false,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.note = note
    self.isPending = isPending
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isPending {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Updating \(title)")
        }
        accessory
      }
      .frame(minHeight: AgentSettingsMetrics.rowHeight)
      if let note {
        AgentSettingsNote(note)
          .padding(.bottom, 6)
      }
    }
  }
}

/// Small secondary text: a locked control's reason, a fallback command.
public struct AgentSettingsNote: View {
  private let text: String
  private let systemImage: String?

  public init(_ text: String, systemImage: String? = nil) {
    self.text = text
    self.systemImage = systemImage
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
      }
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The trailing value of a choice: a borderless menu, or plain text when the
/// viewer can't change it.
public struct AgentSettingsMenu<Content: View>: View {
  private let value: String
  private let accessibilityLabel: String
  private let isEditable: Bool
  private let lockReason: String?
  private let content: Content

  /// - Parameter lockReason: why a read-only value can't change; shown as a
  ///   lock with the reason in its tooltip.
  public init(
    _ value: String,
    accessibilityLabel: String,
    isEditable: Bool = true,
    lockReason: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.value = value
    self.accessibilityLabel = accessibilityLabel
    self.isEditable = isEditable
    self.lockReason = lockReason
    self.content = content()
  }

  public var body: some View {
    if isEditable {
      Menu {
        content
      } label: {
        Text(value)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .frame(maxWidth: 190, alignment: .trailing)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(value)
    } else {
      HStack(spacing: 4) {
        if lockReason != nil {
          Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Text(value)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 190, alignment: .trailing)
      .help(lockReason ?? "")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(value)
      .accessibilityHint(lockReason ?? "")
    }
  }
}

/// A menu item with a checkmark when selected and its description as a
/// second line, so rows don't need to explain each option.
public struct AgentSettingsMenuItem: View {
  private let title: String
  private let description: String?
  private let isSelected: Bool
  private let isDisabled: Bool
  private let action: () -> Void

  public init(
    _ title: String,
    description: String? = nil,
    isSelected: Bool,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.description = description
    self.isSelected = isSelected
    self.isDisabled = isDisabled
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      if isSelected {
        Label { label } icon: { Image(systemName: "checkmark") }
      } else {
        label
      }
    }
    .disabled(isDisabled)
  }

  @ViewBuilder
  private var label: some View {
    Text(title)
    if let description, !description.isEmpty {
      Text(description)
    }
  }
}

/// A limit or the context window: title, detail and value over a thin bar.
public struct AgentSettingsMeterRow<Accessory: View>: View {
  private let title: String
  private let value: String
  private let detail: String?
  private let fraction: Double
  private let accessory: Accessory

  public init(
    _ title: String,
    value: String,
    detail: String?,
    fraction: Double,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.title = title
    self.value = value
    self.detail = detail
    self.fraction = fraction
    self.accessory = accessory()
  }

  private var isHigh: Bool { fraction >= 0.9 }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(title)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(value)
          .monospacedDigit()
          .foregroundStyle(isHigh ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        accessory
      }
      ProgressView(value: min(1, max(0, fraction)))
        .progressViewStyle(.linear)
        .controlSize(.small)
        .tint(isHigh ? .orange : .accentColor)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }
}
