import AppKit
import Combine
import InlineKit

class MainSidebarItemCollectionViewItem: NSCollectionViewItem {
  private var cellView: MainSidebarItemCell? {
    view as? MainSidebarItemCell
  }

  private var displayMode: MainSidebarList.DisplayMode = .compact

  override var isSelected: Bool {
    didSet {
      cellView?.setListSelected(isSelected)
    }
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: NSCollectionViewLayoutAttributes
  ) -> NSCollectionViewLayoutAttributes {
    layoutAttributes.size.height = displayMode.itemHeight
    return layoutAttributes
  }

  override func loadView() {
    view = MainSidebarItemCell(frame: .zero)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cellView?.reset()
  }

  struct Content {
    enum Kind {
      case item(ChatListItem)
      case action(MainSidebarList.ActionItem)
    }

    let kind: Kind
  }

  func configure(
    with item: Content,
    dependencies: AppDependencies,
    events: PassthroughSubject<MainSidebarList.ScrollEvent, Never>,
    highlightNavSelection: Bool,
    isRouteSelected: Bool,
    displayMode: MainSidebarList.DisplayMode
  ) {
    self.displayMode = displayMode
    cellView?.configure(
      with: item,
      dependencies: dependencies,
      events: events,
      highlightNavSelection: highlightNavSelection,
      isRouteSelected: isRouteSelected,
      displayMode: displayMode
    )
  }

  func setDisplayMode(_ displayMode: MainSidebarList.DisplayMode) {
    self.displayMode = displayMode
    cellView?.updateDisplayMode(displayMode)
  }

  func updateSelectionState(routeSelected: Bool, highlightNavSelection: Bool) {
    cellView?.updateSelectionState(
      isRouteSelected: routeSelected,
      highlightNavSelection: highlightNavSelection
    )
  }
}
