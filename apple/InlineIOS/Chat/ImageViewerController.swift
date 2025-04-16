import Nuke
import NukeUI
import UIKit

final class ImageViewerController: UIViewController {
  // MARK: - Properties
    
  private let imageURL: URL
  private weak var sourceView: UIView?
  private let sourceImage: UIImage?
  private let sourceFrame: CGRect
    
  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.delegate = self
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.minimumZoomScale = 1.0
    scrollView.maximumZoomScale = 4.0
    
    return scrollView
  }()

  private lazy var imageContainerView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  private lazy var imageView: LazyImageView = {
    let imageView = LazyImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.layer.cornerRadius = 18
    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.color = .white
    activityIndicator.startAnimating()
    imageView.placeholderView = activityIndicator
      
    return imageView
  }()

  private var imageViewConstraints: [NSLayoutConstraint] = []
  private var transitionImageView: UIImageView?
  private var isControlsVisible = true
    
  private lazy var controlsContainerView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "xmark"), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    button.layer.cornerRadius = 20
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    return button
  }()
    
  private lazy var shareButton: UIButton = {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    button.layer.cornerRadius = 20
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(shareButtonTapped), for: .touchUpInside)
    return button
  }()
    
  // MARK: - Initialization
    
  init(imageURL: URL, sourceView: UIView, sourceImage: UIImage? = nil) {
    self.imageURL = imageURL
    self.sourceView = sourceView
    self.sourceImage = sourceImage
    self.sourceFrame = sourceView.convert(sourceView.bounds, to: nil)
      
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  // MARK: - Lifecycle Methods
    
  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
    setupGestures()
        
    // Hide the main content initially
    scrollView.alpha = 0
    controlsContainerView.alpha = 0
  }
    
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    animateImageIn()
    loadImage()
  }
    
  override var prefersStatusBarHidden: Bool {
    return true
  }
    
  // MARK: - Setup
    
  private func setupViews() {
    view.backgroundColor = .clear
        
    view.addSubview(scrollView)
    scrollView.addSubview(imageContainerView)
    imageContainerView.addSubview(imageView)
        
    view.addSubview(controlsContainerView)
    controlsContainerView.addSubview(closeButton)
    controlsContainerView.addSubview(shareButton)
        
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
      imageContainerView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
      imageContainerView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
      imageContainerView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      imageContainerView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            
      controlsContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      controlsContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsContainerView.heightAnchor.constraint(equalToConstant: 60),
            
      closeButton.topAnchor.constraint(equalTo: controlsContainerView.topAnchor, constant: 16),
      closeButton.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor, constant: 16),
      closeButton.widthAnchor.constraint(equalToConstant: 40),
      closeButton.heightAnchor.constraint(equalToConstant: 40),
         
      shareButton.topAnchor.constraint(equalTo: controlsContainerView.topAnchor, constant: 16),
      shareButton.trailingAnchor.constraint(equalTo: controlsContainerView.trailingAnchor, constant: -16),
      shareButton.widthAnchor.constraint(equalToConstant: 40),
      shareButton.heightAnchor.constraint(equalToConstant: 40)
    ])
        
    setupImageViewConstraints()
  }

  private func setupImageViewConstraints() {
    if !imageViewConstraints.isEmpty {
      NSLayoutConstraint.deactivate(imageViewConstraints)
      imageViewConstraints.removeAll()
    }
     
    imageViewConstraints = [
      imageView.centerXAnchor.constraint(equalTo: imageContainerView.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: imageContainerView.centerYAnchor),
      imageView.widthAnchor.constraint(equalTo: imageContainerView.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: imageContainerView.heightAnchor)
    ]
     
    NSLayoutConstraint.activate(imageViewConstraints)
  }

  private func updateImageViewConstraints() {
    guard let image = imageView.imageView.image else { return }
        
    if !imageViewConstraints.isEmpty {
      NSLayoutConstraint.deactivate(imageViewConstraints)
      imageViewConstraints.removeAll()
    }
        
    let imageWidth = image.size.width
    let imageHeight = image.size.height
    let containerWidth = scrollView.bounds.width
    let containerHeight = scrollView.bounds.height
        
    let widthRatio = containerWidth / imageWidth
    let heightRatio = containerHeight / imageHeight
        
    let minRatio = min(widthRatio, heightRatio)
        
    let scaledWidth = imageWidth * minRatio
    let scaledHeight = imageHeight * minRatio
        
    imageViewConstraints = [
      imageView.centerXAnchor.constraint(equalTo: imageContainerView.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: imageContainerView.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: scaledWidth),
      imageView.heightAnchor.constraint(equalToConstant: scaledHeight)
    ]
        
    NSLayoutConstraint.activate(imageViewConstraints)
        
    scrollView.contentSize = CGSize(width: containerWidth, height: containerHeight)
  }
    
  private func setupGestures() {
    let singleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
    singleTapGesture.numberOfTapsRequired = 1
    view.addGestureRecognizer(singleTapGesture)
      
    let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTapGesture.numberOfTapsRequired = 2
    view.addGestureRecognizer(doubleTapGesture)
      
    singleTapGesture.require(toFail: doubleTapGesture)
      
    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
    panGesture.delegate = self
    view.addGestureRecognizer(panGesture)
  }

  private func loadImage() {
    if let sourceImage = sourceImage {
      imageView.imageView.image = sourceImage
      updateImageViewConstraints()
    }
        
    imageView.url = imageURL
        
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(imageDidLoad),
      name: .imageLoadingDidFinish,
      object: nil
    )
  }

  @objc private func imageDidLoad(_ notification: Notification) {
    guard let loadedImageView = notification.object as? LazyImageView,
          loadedImageView === imageView
    else {
      return
    }
      
    // Reset zoom scale when a new image loads
    scrollView.zoomScale = scrollView.minimumZoomScale
      
    updateImageViewConstraints()

      
    // Center the content
    scrollViewDidZoom(scrollView)
  }

  // MARK: - Animations
    
  private func animateImageIn() {
    // Create a temporary image view for the transition
    let tempImageView = UIImageView(frame: sourceFrame)
    tempImageView.contentMode = .scaleAspectFit
    tempImageView.clipsToBounds = true
    tempImageView.image = sourceImage
    tempImageView.layer.cornerRadius = 16
    view.addSubview(tempImageView)
    transitionImageView = tempImageView
        
    // Calculate the final frame
    let finalFrame: CGRect
    if let image = tempImageView.image {
      let imageRatio = image.size.width / image.size.height
      let screenRatio = view.bounds.width / view.bounds.height
            
      if imageRatio > screenRatio {
        let height = view.bounds.width / imageRatio
        finalFrame = CGRect(
          x: 0,
          y: (view.bounds.height - height) / 2,
          width: view.bounds.width,
          height: height
        )
      } else {
        let width = view.bounds.height * imageRatio
        finalFrame = CGRect(
          x: (view.bounds.width - width) / 2,
          y: 0,
          width: width,
          height: view.bounds.height
        )
      }
    } else {
      finalFrame = view.bounds
    }
        
    UIView.animate(withDuration: 0.25, animations: {
      tempImageView.layer.cornerRadius = 0
      tempImageView.frame = finalFrame
      self.view.backgroundColor = .black
    }, completion: { _ in
            
      self.scrollView.alpha = 1
      self.controlsContainerView.alpha = 1
                
      tempImageView.removeFromSuperview()
      self.transitionImageView = nil
    })
  }
    
  private func animateImageOut(completion: @escaping () -> Void) {
    guard let sourceView = sourceView else {
      UIView.animate(withDuration: 0.2, animations: {
        self.view.alpha = 0
      }, completion: { _ in
        completion()
      })
      return
    }
      
    let updatedFrame = sourceView.convert(sourceView.bounds, to: nil)
      
    scrollView.alpha = 0
    controlsContainerView.alpha = 0
      
    let tempImageView = UIImageView(frame: view.bounds)
    tempImageView.contentMode = .scaleAspectFit
    tempImageView.clipsToBounds = true
    tempImageView.image = imageView.imageView.image ?? sourceImage
    tempImageView.layer.cornerRadius = 0
    view.addSubview(tempImageView)
      
    // Calculate the proper starting frame
    let startFrame: CGRect
    if let image = tempImageView.image {
      let imageRatio = image.size.width / image.size.height
      let screenRatio = view.bounds.width / view.bounds.height
              
      if imageRatio > screenRatio {
        let height = view.bounds.width / imageRatio
        startFrame = CGRect(
          x: 0,
          y: (view.bounds.height - height) / 2,
          width: view.bounds.width,
          height: height
        )
      } else {
        let width = view.bounds.height * imageRatio
        startFrame = CGRect(
          x: (view.bounds.width - width) / 2,
          y: 0,
          width: width,
          height: view.bounds.height
        )
      }
    } else {
      startFrame = view.bounds
    }
      
    tempImageView.frame = startFrame
      
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseInOut, animations: {
      tempImageView.frame = updatedFrame
      tempImageView.layer.cornerRadius = 16
      self.view.backgroundColor = .clear
    }, completion: { _ in
      tempImageView.removeFromSuperview()
      completion()
    })
  }

  // MARK: - Actions

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    if scrollView.zoomScale > scrollView.minimumZoomScale {
      // If already zoomed in, zoom out
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
    } else {
      // Calculate the point to zoom to
      let pointInView = gesture.location(in: imageContainerView)
          
      // Calculate a zoom rect around the tap point
      let zoomScale = min(scrollView.maximumZoomScale, 2.5)
      let width = scrollView.bounds.size.width / zoomScale
      let height = scrollView.bounds.size.height / zoomScale
      let x = pointInView.x - (width / 2.0)
      let y = pointInView.y - (height / 2.0)
          
      let rectToZoom = CGRect(x: x, y: y, width: width, height: height)
      scrollView.zoom(to: rectToZoom, animated: true)
    }
  }

  @objc private func handleSingleTap() {
    toggleControlsVisibility()
  }
    
  @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
    guard scrollView.zoomScale == scrollView.minimumZoomScale else { return }
        
    let translation = gesture.translation(in: view)
    let velocity = gesture.velocity(in: view)
        
    switch gesture.state {
    case .changed:
      imageView.transform = CGAffineTransform(translationX: 0, y: translation.y)
      let progress = min(1.0, abs(translation.y) / 200)
      view.backgroundColor = UIColor.black.withAlphaComponent(1.0 - progress * 0.8)
            
    case .ended, .cancelled:
      if abs(translation.y) > 100 || abs(velocity.y) > 500 {
        let currentFrame = imageView.convert(imageView.bounds, to: view)
        
        scrollView.alpha = 0
        controlsContainerView.alpha = 0
        
        let tempImageView = UIImageView(frame: currentFrame)
        tempImageView.contentMode = .scaleAspectFit
        tempImageView.clipsToBounds = true
        tempImageView.image = imageView.imageView.image ?? sourceImage
        tempImageView.layer.cornerRadius = 0
        
        view.insertSubview(tempImageView, at: 0)
        
        guard let sourceView = sourceView else {
          dismiss(animated: false)
          return
        }
        
        let finalFrame = sourceView.convert(sourceView.bounds, to: nil)
        
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: {
          tempImageView.frame = finalFrame
          tempImageView.layer.cornerRadius = 16
          self.view.backgroundColor = .clear
          self.imageView.alpha = 0
        }, completion: { _ in
          tempImageView.removeFromSuperview()
          self.dismiss(animated: false)
        })
      } else {
        UIView.animate(withDuration: 0.3) {
          self.imageView.transform = .identity
          self.view.backgroundColor = .black
        }
      }
            
    default:
      break
    }
  }

  private func toggleControlsVisibility() {
    isControlsVisible.toggle()
    UIView.animate(withDuration: 0.3) {
      self.controlsContainerView.alpha = self.isControlsVisible ? 1.0 : 0.0
    }
  }
    
  @objc private func closeButtonTapped() {
    animateImageOut {
      self.dismiss(animated: false)
    }
  }
    
  @objc private func saveButtonTapped() {
    guard let image = imageView.imageView.image else { return }
    UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
  }
    
  @objc private func shareButtonTapped() {
    guard let image = imageView.imageView.image else { return }
        
    let activityViewController = UIActivityViewController(
      activityItems: [image],
      applicationActivities: nil
    )
        
    if let popoverController = activityViewController.popoverPresentationController {
      popoverController.sourceView = shareButton
      popoverController.sourceRect = shareButton.bounds
    }
        
    present(activityViewController, animated: true)
  }
    
  @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
    if let error = error {
      print("Error saving image: \(error.localizedDescription)")
            
      let alert = UIAlertController(
        title: "Save Error",
        message: "Could not save the image to your photos.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
    } else {
      let alert = UIAlertController(
        title: "Saved",
        message: "Image saved to your photos.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
    }
  }
    
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - UIScrollViewDelegate

extension ImageViewerController: UIScrollViewDelegate {
  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return imageContainerView
  }
    
  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    // Center the content after zooming
    let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
    let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
        
    scrollView.contentInset = UIEdgeInsets(
      top: offsetY,
      left: offsetX,
      bottom: offsetY,
      right: offsetX
    )
  }
}

// MARK: - UIGestureRecognizerDelegate

extension ImageViewerController: UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if let panGesture = gestureRecognizer as? UIPanGestureRecognizer {
      let velocity = panGesture.velocity(in: view)
      // Only allow vertical panning to dismiss when not zoomed in
      return scrollView.zoomScale == scrollView.minimumZoomScale && abs(velocity.y) > abs(velocity.x)
    }
    return true
  }
    
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // Prevent gesture recognizers from triggering when tapping on buttons
    if touch.view is UIButton {
      return false
    }
    return true
  }
}

// MARK: - Notification Extension

extension Notification.Name {
  static let imageLoadingDidFinish = Notification.Name("imageLoadingDidFinish")
}
