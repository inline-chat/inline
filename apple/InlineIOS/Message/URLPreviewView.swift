import InlineKit
import Nuke
import NukeUI
import SafariServices
import UIKit

class URLPreviewView: UIView {
  private let siteNameLabel = UILabel()
  private let titleLabel = UILabel()
  private let descriptionLabel = UILabel()
  private let imageView: LazyImageView = {
    let view = LazyImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.layer.cornerRadius = 6

    print("")
    return view
  }()

  private var url: URL?
  private weak var parentViewController: UIViewController?

  func configure(
    with preview: UrlPreview,
    photoInfo: PhotoInfo?,
    parentViewController: UIViewController?,
    outgoing: Bool
  ) {
    url = URL(string: preview.url)
    self.parentViewController = parentViewController
    subviews.forEach { $0.removeFromSuperview() }
    print("photoInfo is \(photoInfo)")
    let maxWidth: CGFloat = 280
    let horizontalPadding: CGFloat = 8
    let verticalPadding: CGFloat = 6
    let interLabelSpacing: CGFloat = 4

    let theme = ThemeManager.shared.selected
    let bgColor = outgoing ? .white.withAlphaComponent(0.1) : theme.secondaryTextColor?
      .withAlphaComponent(0.2) ?? .systemGray5.withAlphaComponent(0.2)
    let primaryTextColor = outgoing ? UIColor.white : (theme.primaryTextColor ?? .label)
    let secondaryTextColor = outgoing ? UIColor.white
      .withAlphaComponent(0.7) : (theme.secondaryTextColor ?? .secondaryLabel)

    siteNameLabel.text = preview.siteName
    siteNameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    siteNameLabel.textColor = secondaryTextColor
    siteNameLabel.numberOfLines = 1
    siteNameLabel.isHidden = preview.siteName == nil
    siteNameLabel.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.text = preview.title
    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.textColor = primaryTextColor
    titleLabel.numberOfLines = 0
    titleLabel.isHidden = preview.title == nil
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    descriptionLabel.text = preview.description
    descriptionLabel.font = UIFont.systemFont(ofSize: 14)
    descriptionLabel.textColor = secondaryTextColor
    descriptionLabel.numberOfLines = 0
    descriptionLabel.isHidden = preview.description == nil
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

    imageView.isHidden = true
    var imageAspect: CGFloat = 2.0 / 3.0 // Default aspect ratio
    if let photoInfo, let bestSize = photoInfo.bestPhotoSize(), let urlString = bestSize.cdnUrl,
       let imageUrl = URL(string: urlString)
    {
      imageView.isHidden = false
      imageView.backgroundColor = bgColor.withAlphaComponent(0.2)
      imageView.url = imageUrl
      if let width = bestSize.width, let height = bestSize.height, width > 0, height > 0 {
        imageAspect = CGFloat(height) / CGFloat(width)
      }
    }

    addSubview(siteNameLabel)
    addSubview(titleLabel)
    addSubview(descriptionLabel)
    addSubview(imageView)

    NSLayoutConstraint.deactivate(constraints)
    NSLayoutConstraint.activate([
      // Site name label
      siteNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
      siteNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      siteNameLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Title label
      titleLabel.topAnchor.constraint(equalTo: siteNameLabel.bottomAnchor, constant: interLabelSpacing),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      titleLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Description label
      descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: interLabelSpacing),
      descriptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      descriptionLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Image view
      imageView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: verticalPadding),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      imageView.widthAnchor.constraint(equalToConstant: maxWidth),
      imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: imageAspect),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
    ])

    for label in [siteNameLabel, titleLabel, descriptionLabel] {
      label.preferredMaxLayoutWidth = maxWidth
    }

    backgroundColor = bgColor
    layer.cornerRadius = 8
    layer.masksToBounds = true
    isUserInteractionEnabled = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
  }

  // Calculate image size based on available width/height (max 280x180, keep aspect ratio)
  private func heightForImage(width: CGFloat, height: CGFloat) -> CGFloat {
    let maxWidth: CGFloat = 280
    let maxHeight: CGFloat = 180
    let aspect = width / max(height, 1)
    var w = min(width, maxWidth)
    var h = w / aspect
    if h > maxHeight {
      h = maxHeight
      w = h * aspect
    }
    return h
  }

  @objc private func handleTap() {
    guard let url, let parentVC = parentViewController else { return }

    let safariConfig = SFSafariViewController.Configuration()
    safariConfig.entersReaderIfAvailable = false
    safariConfig.barCollapsingEnabled = true

    let safari = SFSafariViewController(url: url, configuration: safariConfig)
    safari.preferredControlTintColor = ThemeManager.shared.selected.accent
    safari.dismissButtonStyle = .close
    safari.modalPresentationStyle = .pageSheet

    if #available(iOS 15.0, *) {
      if let sheet = safari.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.prefersEdgeAttachedInCompactHeight = true
      }
    }

    parentVC.present(safari, animated: true)
  }
}

#if DEBUG
import SwiftUI

struct URLPreviewView_Previews: PreviewProvider {
  static let previewUrl = "https://www.example.com"
  static let previewSiteName = "Example Site"
  static let previewTitle = "Example Title for a Link Preview"
  static let previewDescription = "This is a description of the link preview. It should be concise and informative."
  static let previewImageUrl =
    "https://44e08acdf82fee3abb51e2515ffef378.r2.cloudflarestorage.com/inline-dev/files/INPoG6WSxR9MC9NRlvjtMQ-e/ecWph8KGLLB7CXtlRyOUckLO99KRpBNI.jpg?X-Amz-Acl=public-read&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=f231f2e0219ab9bcc81c71c93b3615e1%2F20250504%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=20250504T150223Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=cd54e3342fad310cb71560b32b6f98a07c32cdda49607a3b7a06c4fbf60a8c7b"
  static let previewImageWidth = 1_024
  static let previewImageHeight = 666

  static var mockPhotoInfo: PhotoInfo {
    let size = PhotoSize(
      id: 1,
      photoId: 1,
      type: "f",
      width: previewImageWidth,
      height: previewImageHeight,
      size: nil,
      bytes: nil,
      cdnUrl: previewImageUrl,
      localPath: nil
    )
    let photo = Photo(
      id: 1,
      photoId: 1,
      date: Date(),
      format: .jpeg
    )
    return PhotoInfo(photo: photo, sizes: [size])
  }

  static var mockPreview: UrlPreview {
    UrlPreview(
      id: 1,
      url: previewUrl,
      siteName: previewSiteName,
      title: previewTitle,
      description: previewDescription,
      photoId: 1,
      duration: nil
    )
  }

  struct Container: UIViewRepresentable {
    func makeUIView(context: Context) -> URLPreviewView {
      let view = URLPreviewView()
      view.configure(with: mockPreview, photoInfo: mockPhotoInfo, parentViewController: nil, outgoing: true)
      view.translatesAutoresizingMaskIntoConstraints = false
      return view
    }

    func updateUIView(_ uiView: URLPreviewView, context: Context) {}
  }

  static var previews: some View {
    Container()
      .frame(maxWidth: 320, maxHeight: 300)
      .padding()
      .background(Color(.systemBlue))
      .previewLayout(.sizeThatFits)
  }
}
#endif
