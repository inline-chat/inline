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

  func configure(
    with item: HomeChatItem,
    dependencies: AppDependencies,
    events: PassthroughSubject<MainSidebarAppKit.ScrollEvent, Never>
  ) {
    cellView?.configure(
      with: item,
      dependencies: dependencies,
      events: events
    )
  }
}
