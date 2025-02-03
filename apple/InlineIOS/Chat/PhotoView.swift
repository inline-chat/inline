import InlineKit
import Nuke
import NukeUI
import SwiftUI
import UIKit

final class PhotoView: UIView {
  var aspectRatioConstraint: NSLayoutConstraint?

  private let imageView: UIImageView = {
    let view = UIImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  private var fullMessage: FullMessage
  private let maskLayer = CAShapeLayer()
  private let cornerRadius: CGFloat = 16.0
    
  private var hasText: Bool {
    fullMessage.message.text?.isEmpty == false
  }
    
  private var hasReply: Bool {
    fullMessage.message.repliedToMessageId != nil
  }
    
  init(_ fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    setupView()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func setupView() {
    setupImage()
    setupMask()
    setupGestures()
  }
    
  private var imageConstraints: [NSLayoutConstraint] = []
    
  private func setupImage() {
    guard let (isLocal, url) = imageUrl() else { return }
        
    addSubview(imageView)
    
    imageConstraints = [
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    NSLayoutConstraint.activate(imageConstraints)
    let updateImage: (UIImage) -> Void = { [weak self] image in
      guard let self else { return }
      self.imageView.image = image
      self.updateAspectRatio(for: image)
    }
    if isLocal {
      if let image = UIImage(contentsOfFile: url.path) {
        updateImage(image)
      }
    } else {
      let request = ImageRequest(url: url)
      if let image = ImagePipeline.shared.cache.cachedImage(for: request) {
        imageView.image = image.image
      }
            
      Task { @MainActor in
        if let image = try? await ImagePipeline.shared.image(for: request) {
          imageView.image = image
                    
          if var file = fullMessage.file {
            // Save to local cache
            let pathString = image.save(file: file)
            file.localPath = pathString
            try? await AppDatabase.shared.dbWriter.write { db in
              try file.save(db)
            }
          }
        }
      }
    }
  }
    
  private func updateAspectRatio(for image: UIImage) {
    let aspectRatio = image.size.width / image.size.height
    aspectRatioConstraint?.isActive = false
    aspectRatioConstraint = widthAnchor.constraint(
      equalTo: heightAnchor,
      multiplier: aspectRatio
    )
    aspectRatioConstraint?.priority = .required - 1
    aspectRatioConstraint?.isActive = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMask()
  }
    
  private func setupMask() {
    maskLayer.fillColor = UIColor.black.cgColor
    layer.mask = maskLayer
  }

  private func updateMask() {
    let path = UIBezierPath()
    let width = bounds.width
    let height = bounds.height
      
    // Determine corner rounding based on conditions
    let shouldRoundTopCorners = hasText && !hasReply
    let shouldRoundBottomCorners = hasReply && !hasText
    let shouldRoundAllCorners = !hasText && !hasReply
      
    // Create rounded rectangle path
    let roundingCorners: UIRectCorner = {
      if shouldRoundAllCorners {
        return .allCorners
      } else if shouldRoundTopCorners {
        return [.topLeft, .topRight]
      } else if shouldRoundBottomCorners {
        return [.bottomLeft, .bottomRight]
      } else {
        return []
      }
    }()
      
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let bezierPath = UIBezierPath(
      roundedRect: bounds,
      byRoundingCorners: roundingCorners,
      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
    )
      
    maskLayer.path = bezierPath.cgPath
  }
  
  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
        
    let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    addGestureRecognizer(longPressGesture)
  }
    
  private func imageUrl() -> (isLocal: Bool, url: URL)? {
    guard let file = fullMessage.file else { return nil }
        
    if let localFile = file.getLocalURL() {
      return (isLocal: true, url: localFile)
    } else if let tempUrl = file.temporaryUrl,
              let url = URL(string: tempUrl)
    {
      return (isLocal: false, url: url)
    }
    return nil
  }
    
  @objc private func handleTap() {
//    guard let image = imageView.image else { return }
//
//    let previewVC = UIHostingController(rootView: PhotoPreviewView(
//      image: image,
//      caption: .constant(""),
//      isPresented: .constant(true),
//      onSend: { _, _ in }
//    ))
//    previewVC.modalPresentationStyle = .fullScreen
//    previewVC.modalTransitionStyle = .crossDissolve
//
//    window?.rootViewController?.present(previewVC, animated: true)
  }
    
  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
        
    let menuController = UIMenuController.shared
    becomeFirstResponder()
        
    let copyItem = UIMenuItem(title: "Copy", action: #selector(copyImage))
    let saveItem = UIMenuItem(title: "Save", action: #selector(saveImage))
    menuController.menuItems = [copyItem, saveItem]
        
    let targetRect = bounds
    menuController.showMenu(from: self, rect: targetRect)
  }
    
  @objc private func copyImage() {
    guard let image = imageView.image else { return }
    UIPasteboard.general.image = image
  }
    
  @objc private func saveImage() {
    guard let image = imageView.image else { return }
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
  }
    
  override var canBecomeFirstResponder: Bool {
    true
  }
}
