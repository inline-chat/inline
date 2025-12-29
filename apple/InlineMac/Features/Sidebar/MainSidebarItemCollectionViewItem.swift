import AppKit
import Combine
import InlineKit

class MainSidebarItemCollectionViewItem: NSCollectionViewItem {
  private var cellView: MainSidebarItemCell? {
    view as? MainSidebarItemCell
  }

  private var isHeader: Bool = false

  override var isSelected: Bool {
    didSet {
      cellView?.setListSelected(isSelected)
    }
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: NSCollectionViewLayoutAttributes
  ) -> NSCollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
    attributes.size.height = isHeader ? 20 : MainSidebar.itemHeight
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
      case header(title: String, symbol: String)
    }

    let kind: Kind
  }

  func configure(
    with item: Content,
    dependencies: AppDependencies,
    events: PassthroughSubject<MainSidebarList.ScrollEvent, Never>,
    highlightNavSelection: Bool
  ) {
    if case .header = item.kind {
      isHeader = true
    } else {
      isHeader = false
    }
    cellView?.configure(
      with: item,
      dependencies: dependencies,
      events: events,
      highlightNavSelection: highlightNavSelection
    )
  }
}
