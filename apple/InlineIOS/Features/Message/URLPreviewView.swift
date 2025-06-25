import InlineKit
import Nuke
import NukeUI
import SafariServices
import UIKit

class URLPreviewView: UIView {
  private let rectangleView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.mask = CAShapeLayer()
    return view
  }()

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

  private weak var parentViewController: UIViewController?
  private var previewUrl: URL?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupTapGesture()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupTapGesture()
  }

  private func setupTapGesture() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
    isUserInteractionEnabled = true
  }

  @objc private func handleTap() {
    guard let url = previewUrl else { return }
    UIApplication.shared.open(url)
  }

  func configure(
    with preview: UrlPreview,
    photoInfo: PhotoInfo?,
    parentViewController: UIViewController?,
    outgoing: Bool
  ) {
    self.parentViewController = parentViewController
    previewUrl = URL(string: preview.url)

    subviews.forEach { $0.removeFromSuperview() }

    let maxWidth: CGFloat = 280
    let horizontalPadding: CGFloat = 8
    let verticalPadding: CGFloat = 6
    let interLabelSpacing: CGFloat = 4
    let rectangleWidth: CGFloat = 4
    let contentSpacing: CGFloat = 8
    let cornerRadius: CGFloat = 8

    let theme = ThemeManager.shared.selected
    let bgColor = outgoing ? .white.withAlphaComponent(0.1) : theme.secondaryTextColor?
      .withAlphaComponent(0.2) ?? .systemGray5.withAlphaComponent(0.2)
    let primaryTextColor = outgoing ? UIColor.white : (theme.primaryTextColor ?? .label)
    let secondaryTextColor = outgoing ? UIColor.white
      .withAlphaComponent(0.7) : (theme.primaryTextColor?.withAlphaComponent(0.7) ?? .secondaryLabel)
    let rectangleColor = outgoing ? UIColor.white : (theme.accent ?? .systemBlue)

    siteNameLabel.text = preview.siteName
    siteNameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    siteNameLabel.textColor = primaryTextColor
    siteNameLabel.numberOfLines = 1
    siteNameLabel.isHidden = preview.siteName == nil
    siteNameLabel.translatesAutoresizingMaskIntoConstraints = false
    siteNameLabel.isUserInteractionEnabled = false

    titleLabel.text = preview.title
    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.textColor = primaryTextColor
    titleLabel.numberOfLines = 0
    titleLabel.isHidden = preview.title == nil
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.isUserInteractionEnabled = false

    descriptionLabel.text = preview.description
    descriptionLabel.font = UIFont.systemFont(ofSize: 14)
    descriptionLabel.textColor = secondaryTextColor
    descriptionLabel.numberOfLines = 0
    descriptionLabel.isHidden = preview.description == nil
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.isUserInteractionEnabled = false

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
    imageView.isUserInteractionEnabled = false

    rectangleView.backgroundColor = rectangleColor
    addSubview(rectangleView)
    addSubview(siteNameLabel)
    addSubview(titleLabel)
    addSubview(descriptionLabel)
    addSubview(imageView)

    NSLayoutConstraint.deactivate(constraints)

    let maxHeight: CGFloat = 200
    var isPortrait = false
    var imageWidth: CGFloat = maxWidth
    var imageHeight: CGFloat = maxHeight
    if let photoInfo, let bestSize = photoInfo.bestPhotoSize(), let width = bestSize.width,
       let height = bestSize.height,
       width > 0, height > 0
    {
      isPortrait = height > width
      if isPortrait {
        // Portrait: limit by height
        imageHeight = min(CGFloat(height), maxHeight)
        imageWidth = min(CGFloat(width) * (imageHeight / CGFloat(height)), maxWidth)
      } else {
        // Landscape: limit by width
        imageWidth = min(CGFloat(width), maxWidth)
        imageHeight = min(CGFloat(height) * (imageWidth / CGFloat(width)), maxHeight)
      }
    }
    NSLayoutConstraint.activate([
      // Rectangle accent line
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Site name label
      siteNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
      siteNameLabel.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor, constant: contentSpacing),
      siteNameLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Title label
      titleLabel.topAnchor.constraint(equalTo: siteNameLabel.bottomAnchor, constant: interLabelSpacing),
      titleLabel.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor, constant: contentSpacing),
      titleLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Description label
      descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: interLabelSpacing),
      descriptionLabel.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor, constant: contentSpacing),
      descriptionLabel.widthAnchor.constraint(equalToConstant: maxWidth),

      // Image view
      imageView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: verticalPadding),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: rectangleWidth / 2),
      imageView.widthAnchor.constraint(equalToConstant: imageWidth),
      imageView.heightAnchor.constraint(equalToConstant: imageHeight),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
    ])

    for label in [siteNameLabel, titleLabel, descriptionLabel] {
      label.preferredMaxLayoutWidth = maxWidth
    }

    backgroundColor = bgColor
    layer.cornerRadius = cornerRadius
    layer.masksToBounds = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Add rounded corners to the accent line
    let path = UIBezierPath(
      roundedRect: rectangleView.bounds,
      byRoundingCorners: [.topLeft, .bottomLeft],
      cornerRadii: CGSize(width: 8, height: 8)
    )
    if let mask = rectangleView.layer.mask as? CAShapeLayer {
      mask.path = path.cgPath
    }
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
