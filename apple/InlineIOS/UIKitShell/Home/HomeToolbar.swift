import Auth
import Combine
import GRDB
import InlineCompatUI
import InlineGrid
import InlineKit
import InlineUI
import UIKit

/// Home navigation bar: space switcher title on the leading side; connection spinner, options
/// menu, notifications and account on the trailing side.
///
/// iOS 26+: glass groups separated by fixed spacers, account avatar outside the shared glass,
/// New Thread lives in the tab bar. Before 26: a compose button joins the trailing items.
@MainActor
enum HomeToolbar {
  static func apply(to item: UINavigationItem, surface: HomeListViewController.Surface, shell: MainShellController) {
    item.leftBarButtonItem = UIBarButtonItem(customView: spaceSwitcher(shell: shell))
    item.leftItemsSupplementBackButton = false
    item.title = nil

    var trailing: [UIBarButtonItem] = []
    let usesGlassGroups: Bool
    if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
      usesGlassGroups = true
    } else {
      usesGlassGroups = false
    }

    trailing.append(accountItem(shell: shell, usesGlass: usesGlassGroups))
    if usesGlassGroups { trailing.append(.fixedSpace(0)) }
    trailing.append(notificationsItem())
    if usesGlassGroups { trailing.append(.fixedSpace(0)) }
    trailing.append(optionsItem(surface: surface, shell: shell))
    if !usesGlassGroups {
      let compose = UIBarButtonItem(
        image: UIImage(systemName: "square.and.pencil"),
        primaryAction: UIAction { [weak shell] _ in shell?.startNewThread() }
      )
      compose.accessibilityLabel = String(localized: "New Thread")
      compose.isEnabled = !shell.home.isCreatingThread
      trailing.append(compose)
    }
    if let state = Api.realtime.stateObject.displayedConnectionState {
      if usesGlassGroups { trailing.append(.fixedSpace(0)) }
      let spinner = UIBarButtonItem(customView: ConnectionSpinnerView.toolbarItem())
      spinner.accessibilityLabel = state.title
      trailing.append(spinner)
    }
    item.rightBarButtonItems = trailing
  }

  // MARK: Space switcher

  private static func spaceSwitcher(shell: MainShellController) -> UIButton {
    let title = shell.activeSpace?.displayName ?? String(localized: "Home")
    var config = UIButton.Configuration.plain()
    var attributes = AttributeContainer()
    attributes.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
    attributes.foregroundColor = UIColor.label
    config.attributedTitle = AttributedString(title, attributes: attributes)
    config.image = UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    )
    config.imagePlacement = .trailing
    config.imagePadding = 5
    config.baseForegroundColor = .secondaryLabel
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    let button = UIButton(configuration: config)
    button.showsMenuAsPrimaryAction = true
    button.menu = spaceMenu(shell: shell)
    button.accessibilityLabel = title
    button.accessibilityHint = String(localized: "Switch space")
    return button
  }

  private static func spaceMenu(shell: MainShellController) -> UIMenu {
    let activeID = shell.home.activeSpaceId
    let home = UIAction(
      title: String(localized: "Home"),
      image: UIImage(systemName: "house"),
      state: activeID == nil ? .on : .off
    ) { [weak shell] _ in shell?.selectSpace(nil) }
    let spaces = shell.spaces.spaces
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      .map { space in
        UIAction(
          title: space.displayName,
          image: UIImage(systemName: "building.2"),
          state: activeID == space.id ? .on : .off
        ) { [weak shell] _ in shell?.selectSpace(space.id) }
      }
    let create = UIAction(
      title: String(localized: "Create Space"),
      image: UIImage(systemName: "plus")
    ) { [weak shell] _ in shell?.router.presentSheet(.createSpace) }
    return UIMenu(children: [
      UIMenu(options: .displayInline, children: [home] + spaces),
      UIMenu(options: .displayInline, children: [create]),
    ])
  }

  // MARK: Options

  private static func optionsItem(surface: HomeListViewController.Surface, shell: MainShellController) -> UIBarButtonItem {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis"),
      menu: optionsMenu(surface: surface, shell: shell)
    )
    item.accessibilityLabel = String(localized: "More")
    item.accessibilityIdentifier = "chatListOptions"
    return item
  }

  private static func optionsMenu(surface: HomeListViewController.Surface, shell: MainShellController) -> UIMenu {
    let home = shell.home
    let showsFilter = surface == .allChats
    let showsGrid: Bool = if #available(iOS 18.0, *) {
      GridHomeEntryProjection(store: GridIOSRuntime.shared.rooms, spaceID: nil).showsMenuEntry
    } else {
      false
    }
    let grid: UIAction? = showsGrid
      ? UIAction(title: String(localized: "Grid"), image: UIImage(systemName: "square.grid.2x2")) { [weak shell] _ in
        shell?.open(.grid(initialSpaceID: shell?.home.activeSpaceId))
      }
      : nil
    let archived = UIAction(title: "Archived Chats", image: UIImage(systemName: "archivebox")) { [weak shell] _ in
      shell?.open(.archived)
    }
    let invite = UIAction(title: "Invite", image: UIImage(systemName: "person.badge.plus")) { [weak shell] _ in
      guard let shell else { return }
      if let space = shell.activeSpace {
        shell.router.presentSheet(.addMember(spaceId: space.id))
      } else {
        shell.router.presentSheet(.inviteToInline)
      }
    }
    let itemSize = UIMenu(
      title: "Item Size",
      subtitle: home.renderMode.title,
      image: UIImage(systemName: "textformat.size"),
      options: .singleSelection,
      children: ExperimentalHomeChatItemRenderMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == home.renderMode ? .on : .off) { [weak home] _ in
          home?.renderMode = mode
        }
      }
    )
    let sort = UIMenu(
      title: "Sort",
      subtitle: home.sortMode.title,
      image: UIImage(systemName: "arrow.up.arrow.down"),
      options: .singleSelection,
      children: ExperimentalHomeSortMode.allCases.map { mode in
        UIAction(title: mode.title, state: mode == home.sortMode ? .on : .off) { [weak home] _ in
          home?.sortMode = mode
        }
      }
    )
    let filter: UIMenu? = showsFilter ? UIMenu(
      title: "Filter",
      subtitle: home.allChatsFilter == .unread ? "Unread" : "All Chats",
      image: UIImage(systemName: "line.3.horizontal.decrease"),
      options: .singleSelection,
      children: ChatListFilter.allCases.map { value in
        UIAction(
          title: value == .unread ? "Unread" : "All Chats",
          state: value == home.allChatsFilter ? .on : .off
        ) { [weak home] _ in home?.allChatsFilter = value }
      }
    ) : nil

    var viewChildren: [UIMenuElement] = [itemSize, sort]
    if showsFilter, home.activeSpaceId == nil, !shell.spaces.spaces.isEmpty {
      let spaces = shell.spaces.spaces
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      let excluded = spaces.filter { home.exclusions.contains($0.id) }.count
      let subtitle = switch excluded {
      case 0: "All spaces shown"
      case 1: "1 space excluded"
      default: "\(excluded) spaces excluded"
      }
      viewChildren.append(UIMenu(
        title: "Exclude Spaces from Home",
        subtitle: subtitle,
        image: UIImage(systemName: "eye.slash"),
        children: spaces.map { space in
          UIAction(title: space.displayName, state: home.exclusions.contains(space.id) ? .on : .off) { [weak home] _ in
            guard let home else { return }
            home.exclusions = home.exclusions.toggling(space.id)
          }
        }
      ))
    }
    let viewOptions = UIMenu(title: "View Options", image: UIImage(systemName: "slider.horizontal.3"), children: viewChildren)
    let viewSection = UIMenu(options: .displayInline, children: (filter.map { [$0] } ?? []) + [viewOptions, archived])

    let spaceSection: UIMenu
    if let space = shell.activeSpace {
      spaceSection = UIMenu(title: space.displayName, options: .displayInline, children: [
        invite,
        UIAction(title: "Members", image: UIImage(systemName: "person.2")) { [weak shell] _ in
          shell?.router.presentSheet(.members(spaceId: space.id))
        },
        UIAction(title: "Manage", image: UIImage(systemName: "gearshape.2")) { [weak shell] _ in
          shell?.open(.spaceSettings(spaceId: space.id))
        },
      ])
    } else {
      spaceSection = UIMenu(options: .displayInline, children: [invite])
    }
    return UIMenu(children: (grid.map { [$0] } ?? []) + [viewSection, spaceSection])
  }

  // MARK: Notifications

  private static func notificationsItem() -> UIBarButtonItem {
    let settings = INUserSettings.current.notification
    let item = UIBarButtonItem(
      image: UIImage(systemName: settings.mode.systemImage),
      menu: UIMenu(children: NotificationModeMenu.menu(settings: settings).children)
    )
    item.accessibilityLabel = String(localized: "Notifications")
    item.accessibilityValue = settings.mode.title
    return item
  }

  // MARK: Account

  private static func accountItem(shell: MainShellController, usesGlass: Bool) -> UIBarButtonItem {
    let button = AccountAvatarButton()
    button.addAction(UIAction { [weak shell] _ in shell?.router.presentSheet(.settings) }, for: .touchUpInside)
    let item = UIBarButtonItem(customView: button)
    item.accessibilityLabel = String(localized: "App Settings")
    if usesGlass, #available(iOS 26.0, *) {
      item.hidesSharedBackground = true
    }
    return item
  }
}

/// The signed-in person's avatar, kept current from the database.
final class AccountAvatarButton: UIButton {
  private let avatar = UserAvatarLayerView()
  private var cancellable: AnyCancellable?

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    avatar.isUserInteractionEnabled = false
    avatar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatar)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 30),
      heightAnchor.constraint(equalToConstant: 30),
      avatar.topAnchor.constraint(equalTo: topAnchor),
      avatar.bottomAnchor.constraint(equalTo: bottomAnchor),
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
      avatar.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    cancellable = ValueObservation
      .tracking { db in try CurrentUser().fetch(db) }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] user in
        guard let self, let user else { return }
        avatar.configure(with: user, size: 30)
      })
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
