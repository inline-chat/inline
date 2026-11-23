import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import UIKit

/// UIKit port of `ExperimentalMembersSheetView`: the space's members (local first, refreshed from
/// the server once on open and on Refresh), each with avatar and role; tapping one opens the DM.
@MainActor
final class SpaceMembersViewController: FormViewController {
  private unowned let shell: MainShellController
  private let spaceId: Int64
  private let viewModel: SpaceFullMembersViewModel
  private var cancellables: Set<AnyCancellable> = []
  private var didRunInitialFetch = false

  init(spaceId: Int64, shell: MainShellController) {
    self.spaceId = spaceId
    self.shell = shell
    viewModel = SpaceFullMembersViewModel(db: AppDatabase.shared, spaceId: spaceId)
    super.init(style: .insetGrouped)
    title = String(localized: "Members")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet to present for `Sheet.members(spaceId:)`.
  static func makeSheet(spaceId: Int64, shell: MainShellController) -> UIViewController {
    ShellSheetSupport.wrap(SpaceMembersViewController(spaceId: spaceId, shell: shell), shell: shell)
  }

  override func registerCells(in tableView: UITableView) {
    SheetPeerRowCell.register(in: tableView)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        closeShellSheet(shell)
      }
    )
    // The view model publishes synchronously from local data (immediate scheduling).
    viewModel.$members
      .dropFirst()
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
    viewModel.$space
      .dropFirst()
      .sink { [weak self] _ in self?.setNeedsFormUpdate() }
      .store(in: &cancellables)
    viewModel.$isLoading
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.updateRefreshItem()
        self?.setNeedsFormUpdate()
      }
      .store(in: &cancellables)
    updateRefreshItem()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didRunInitialFetch else { return }
    didRunInitialFetch = true
    refresh()
  }

  private func updateRefreshItem() {
    if viewModel.isLoading {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      let item = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        primaryAction: UIAction { [weak self] _ in self?.refresh() }
      )
      item.accessibilityLabel = String(localized: "Refresh")
      navigationItem.rightBarButtonItem = item
    }
  }

  private func refresh() {
    Task { [weak self] in
      await self?.viewModel.refetchMembers()
    }
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let members = viewModel.filteredMembers
    FormSection(
      "members",
      header: viewModel.space?.displayName,
      footer: footerText(count: members.count)
    ) {
      if members.isEmpty {
        if viewModel.isLoading {
          FormRow("loading", title: String(localized: "Loading members…"), accessory: .activity)
        } else {
          FormRow.note("empty", String(localized: "No members yet"))
        }
      } else {
        for member in members {
          FormRow.peer("member-\(member.id)", content(for: member)) { [weak self] in
            self?.openChat(userId: member.userInfo.user.id)
          }
        }
      }
    }
  }

  private func footerText(count: Int) -> String? {
    if let error = viewModel.errorMessage, count == 0 { return error }
    guard count > 0 else { return nil }
    return count == 1 ? String(localized: "1 member") : "\(count) members"
  }

  private func content(for member: FullMemberItem) -> SheetPeerRowCell.Content {
    let user = member.userInfo.user
    return SheetPeerRowCell.Content(
      identity: .user(member.userInfo),
      title: user.displayName,
      subtitle: user.username.map { "@\($0)" },
      trailingText: Self.roleTitle(member.member.role),
      trailingSymbol: "bubble.left.and.bubble.right",
      avatarSize: 34
    )
  }

  private static func roleTitle(_ role: MemberRole) -> String? {
    switch role {
    case .owner: String(localized: "Owner")
    case .admin: String(localized: "Admin")
    case .member: nil
    }
  }

  /// `router.dismissSheet()` + open the DM. `closeShellSheet` clears the router's sheet itself,
  /// so the shell does not dismiss it a second time.
  private func openChat(userId: Int64) {
    let shell = shell
    closeShellSheet(shell)
    shell.open(.chat(peer: .user(id: userId)))
  }
}
