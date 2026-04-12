#if os(iOS)
import Combine
import Photos
import SwiftUI

public extension Notification.Name {
  static let attachmentPickerRecentMediaDidChange = Notification.Name("attachmentPickerRecentMediaDidChange")
}

public enum AttachmentPickerRecentMediaChangeUserInfo {
  public static let localIdentifiersKey = "localIdentifiers"
}

public struct AttachmentPickerActions {
  public let openCamera: () -> Void
  public let openLibrary: () -> Void
  public let openFiles: () -> Void
  public let openRecentItem: (AttachmentPickerModel.RecentItem) -> Void
  public let openRecentItems: ([AttachmentPickerModel.RecentItem]) -> Void
  public let manageLimitedAccess: () -> Void

  public init(
    openCamera: @escaping () -> Void,
    openLibrary: @escaping () -> Void,
    openFiles: @escaping () -> Void,
    openRecentItem: @escaping (AttachmentPickerModel.RecentItem) -> Void,
    openRecentItems: @escaping ([AttachmentPickerModel.RecentItem]) -> Void,
    manageLimitedAccess: @escaping () -> Void
  ) {
    self.openCamera = openCamera
    self.openLibrary = openLibrary
    self.openFiles = openFiles
    self.openRecentItem = openRecentItem
    self.openRecentItems = openRecentItems
    self.manageLimitedAccess = manageLimitedAccess
  }
}

public struct AttachmentPickerSheet: View {
  @State private var model: AttachmentPickerModel

  private let actions: AttachmentPickerActions

  @MainActor
  public init(
    actions: AttachmentPickerActions,
    recentLimit: Int = AttachmentPickerModel.defaultRecentLimit
  ) {
    _model = State(initialValue: AttachmentPickerModel(recentLimit: recentLimit))
    self.actions = actions
  }

  @MainActor
  init(
    model: AttachmentPickerModel,
    actions: AttachmentPickerActions
  ) {
    _model = State(initialValue: model)
    self.actions = actions
  }

  public var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if model.selectedRecentItems.isEmpty == false {
        bottomSendButtonOverlay
          .padding(.horizontal, AttachmentPickerTileMetrics.floatingButtonHorizontalPadding)
          .padding(.top, 8)
          .padding(.bottom, AttachmentPickerTileMetrics.floatingButtonBottomInset)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(.snappy(duration: 0.28, extraBounce: 0), value: model.selectedRecentItems.isEmpty)
    .task {
      await model.reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: .attachmentPickerRecentMediaDidChange)) { notification in
      Task {
        let localIdentifiers = notification.userInfo?[AttachmentPickerRecentMediaChangeUserInfo.localIdentifiersKey] as? [String]
        if let localIdentifiers {
          await model.reload(promotingLocalIdentifiers: localIdentifiers)
        } else {
          await model.reload()
        }
      }
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 18) {
      mediaHeader

      recentStrip

      if let message = emptyStateMessage {
        Text(message)
          .font(.footnote.weight(.regular))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 2)
      }

      Divider()
        .padding(.horizontal, 20)

      actionList
    }
    .padding(.top, 20)
    .padding(.bottom, AttachmentPickerTileMetrics.contentBottomPadding)
  }

  private var mediaHeader: some View {
    ZStack(alignment: .leading) {
      if model.showsLimitedAccessNotice {
        LimitedLibraryNotice(action: actions.manageLimitedAccess)
      }

      Text("Select Media")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 20)
        .allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var recentStrip: some View {
    AttachmentPickerRecentStrip(
      items: model.recentItems,
      selectedItemIds: model.selectedRecentItemIds,
      openCamera: actions.openCamera,
      openLibrary: libraryAction,
      toggleSelection: { localIdentifier in
        model.toggleRecentSelection(localIdentifier: localIdentifier)
      }
    )
  }

  private var actionList: some View {
    VStack(spacing: 18) {
      listActionButton(
        title: "Files",
        systemImage: "folder",
        subtitle: "Browse iCloud Drive and on-device files",
        action: actions.openFiles
      )
      .background(Color.clear)
    }
    .padding(.horizontal, 20)
  }

  private var sendSelectedButtonTitle: String {
    attachmentPickerSendSelectedButtonTitle(for: model.selectedRecentItems)
  }

  @ViewBuilder
  private var bottomSendButtonOverlay: some View {
    if model.selectedRecentItems.isEmpty == false {
      AttachmentPickerFloatingSendButton(
        title: sendSelectedButtonTitle,
        action: sendSelectedItems
      )
      .transition(.attachmentPickerFooter)
    }
  }

  private func sendSelectedItems() {
    let selectedItems = model.selectedRecentItems
    guard selectedItems.isEmpty == false else { return }
    actions.openRecentItems(selectedItems)
    model.clearRecentSelection()
  }

  private func listActionButton(
    title: String,
    systemImage: String,
    subtitle: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .regular))
          .foregroundStyle(.primary)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body.weight(.regular))
            .foregroundStyle(.primary)

          if let subtitle {
            Text(subtitle)
              .font(.footnote.weight(.regular))
              .foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private var libraryAction: () -> Void {
    switch resolveAttachmentPickerLibraryActionTarget(
      showsLimitedAccessNotice: model.showsLimitedAccessNotice
    ) {
      case .openLibrary:
        return actions.openLibrary
      case .manageLimitedAccess:
        return actions.manageLimitedAccess
    }
  }

  private var emptyStateMessage: String? {
    if model.isLoading {
      return nil
    }

    switch model.authorizationStatus {
      case .denied, .restricted:
        return "Allow photo access to see recent media here."
      case .authorized, .limited:
        return nil
      case .notDetermined:
        return nil
      @unknown default:
        return nil
    }
  }
}

private struct AttachmentPickerFooterTransitionModifier: ViewModifier {
  let opacity: Double
  let blurRadius: CGFloat
  let scale: CGFloat
  let offsetY: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .blur(radius: blurRadius)
      .scaleEffect(scale, anchor: .bottom)
      .offset(y: offsetY)
  }
}

private extension AnyTransition {
  static var attachmentPickerFooter: AnyTransition {
    .modifier(
      active: AttachmentPickerFooterTransitionModifier(
        opacity: 0,
        blurRadius: 4,
        scale: 0.934,
        offsetY: 36
      ),
      identity: AttachmentPickerFooterTransitionModifier(
        opacity: 1,
        blurRadius: 0,
        scale: 1,
        offsetY: 0
      )
    )
  }
}
#endif
