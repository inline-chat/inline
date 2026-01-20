import AppKit
import Combine
import InlineKit

class MainSidebarItemCollectionViewItem: NSCollectionViewItem {
  private var cellView: MainSidebarItemCell? {
    view as? MainSidebarItemCell
  }

  override var isSelected: Bool {
    didSet {
      cellView?.setListSelected(isSelected)
    }
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: NSCollectionViewLayoutAttributes
  ) -> NSCollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
    attributes.size.height = MainSidebar.itemHeight
    return attributes
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
    }

    let kind: Kind
  }

  func configure(
    with item: Content,
    dependencies: AppDependencies,
    events: PassthroughSubject<MainSidebarList.ScrollEvent, Never>,
    highlightNavSelection: Bool
  ) {
    cellView?.configure(
      with: item,
      dependencies: dependencies,
      events: events,
      highlightNavSelection: highlightNavSelection
    )
  }
}
