import AppKit
import Combine
import InlineKit

class MainSidebarItemCollectionViewItem: NSCollectionViewItem {
  private var cellView: MainSidebarItemCell? {
    view as? MainSidebarItemCell
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
    events: PassthroughSubject<MainSidebarList.ScrollEvent, Never>
  ) {
    cellView?.configure(
      with: item,
      dependencies: dependencies,
      events: events
    )
  }
}
