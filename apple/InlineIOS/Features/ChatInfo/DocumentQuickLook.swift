import QuickLook
import UIKit

/// Shows a downloaded file in QuickLook from the top view controller, titled with the file's
/// name rather than its cache name.
@MainActor
enum DocumentQuickLook {
  @discardableResult
  static func present(url: URL, title: String?) -> Bool {
    guard let presenter = activeTopViewController() else { return false }
    let controller = Controller(item: Item(url: url, title: title))
    presenter.present(controller, animated: true)
    return true
  }

  private final class Item: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String?) {
      previewItemURL = url
      previewItemTitle = title?.isEmpty == false ? title : url.lastPathComponent
    }
  }

  /// Owns its data source: QuickLook holds it weakly.
  private final class Controller: QLPreviewController, QLPreviewControllerDataSource {
    private let item: Item

    init(item: Item) {
      self.item = item
      super.init(nibName: nil, bundle: nil)
      dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
  }
}
