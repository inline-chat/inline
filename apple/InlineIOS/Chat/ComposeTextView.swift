import Logger
import ObjectiveC
import UIKit
import UniformTypeIdentifiers

class ComposeTextView: UITextView {
  private var placeholderLabel: UILabel?
  private var lastText: String = ""
  weak var composeView: ComposeView?
  private var processedRanges = Set<String>()
  private var recentlySentImageHashes = Set<Int>()
  private let processingLock = NSLock()
  private let textModificationQueue = DispatchQueue(
    label: "com.app.textview.modification",
    qos: .userInitiated
  )

  init(composeView: ComposeView) {
    self.composeView = composeView
    super.init(frame: .zero, textContainer: nil)
    setupTextView()
    setupPlaceholder()
    setupNotifications()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    Log.shared.debug("ComposeTextView deinit")
  }

  private func setupTextView() {
    backgroundColor = .clear
    allowsEditingTextAttributes = true
    font = .systemFont(ofSize: 17)
    typingAttributes[.font] = font
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    translatesAutoresizingMaskIntoConstraints = false
    tintColor = ColorManager.shared.selectedColor
  }

  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .left
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: textContainer.lineFragmentPadding + textContainerInset.left
      ),
      label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top)
    ])

    placeholderLabel = label
  }

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(textDidChange),
      name: UITextView.textDidChangeNotification,
      object: self
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )
  }

  @objc private func textDidChange() {
    showPlaceholder(text.isEmpty)

    if text.contains("￼") || attributedText.string.contains("￼") {
      handleStickerDetection()
    }

    lastText = text
    fixFontSizeAfterStickerInsertion()
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.handleStickerDetection()
    }
  }

  func showPlaceholder(_ show: Bool) {
    placeholderLabel?.alpha = show ? 1 : 0
  }

  override func insertText(_ text: String) {
    super.insertText(text)

    if text.contains("￼") {
      handleStickerDetection()
    }
  }

  override func paste(_ sender: Any?) {
    let pasteboard = UIPasteboard.general
    let hadImage = pasteboard.hasImages
    let originalImage = pasteboard.image

    super.paste(sender)

    if hadImage, let image = originalImage {
      if let imageData = image.pngData() ?? image.jpegData(compressionQuality: 0.9) {
        DispatchQueue.main.async { [weak self] in
          self?.sendStickerImage(imageData, metadata: ["source": "direct_pasteboard"])

          if let range = self?.text.range(of: "￼") {
            let nsRange = NSRange(range, in: self?.text ?? "")
            self?.safelyRemoveAttachment(at: nsRange)
          }
        }
        return
      }
    }

    if text.contains("￼") || attributedText.string.contains("￼") {
      handleStickerDetection()
    }
  }

  override var attributedText: NSAttributedString! {
    didSet {
      if attributedText?.string.contains("￼") == true {
        handleStickerDetection()
      }
    }
  }

  private func fixFontSizeAfterStickerInsertion() {
    guard let attributedText = attributedText?.mutableCopy() as? NSMutableAttributedString,
          attributedText.length > 0
    else {
      return
    }

    var needsFix = false
    attributedText.enumerateAttribute(
      .font,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, stop in
      if let font = value as? UIFont, font.pointSize != 17 {
        needsFix = true
        stop.pointee = true
      }
    }

    if needsFix {
      attributedText.addAttribute(
        .font,
        value: UIFont.systemFont(ofSize: 17),
        range: NSRange(location: 0, length: attributedText.length)
      )
      attributedText.addAttribute(
        .foregroundColor,
        value: UIColor.label,
        range: NSRange(location: 0, length: attributedText.length)
      )

      self.attributedText = attributedText
    }
  }

  private func handleStickerDetection() {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self,
      selector: #selector(performStickerDetection),
      object: nil
    )
    perform(#selector(performStickerDetection), with: nil, afterDelay: 0.1)
  }

  @objc private func performStickerDetection() {
    checkForNewAttachments()
  }

  public func checkForNewAttachments() {
    guard let attributedText = attributedText else { return }

    let string = attributedText.string
    var rangesToProcess: [NSRange] = []

    for (index, char) in string.enumerated() {
      if char == "\u{FFFC}" {
        let nsRange = NSRange(location: index, length: 1)
        rangesToProcess.append(nsRange)
      }
    }

    if !rangesToProcess.isEmpty {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        for range in rangesToProcess {
          if range.location < attributedText.length {
            let attributes = attributedText.attributes(
              at: range.location,
              effectiveRange: nil
            )
            self.processReplacementCharacter(at: range, attributes: attributes)
          }
        }
      }
    }
  }

  private func processReplacementCharacter(
    at range: NSRange,
    attributes: [NSAttributedString.Key: Any]
  ) {
    let rangeIdentifier = "\(range.location):\(range.length):\(Date().timeIntervalSince1970)"

    processingLock.lock()

    if processedRanges.contains(rangeIdentifier) {
      processingLock.unlock()
      return
    }

    processedRanges.insert(rangeIdentifier)
    processingLock.unlock()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.processingLock.lock()
      self?.processedRanges.remove(rangeIdentifier)
      self?.processingLock.unlock()
    }

    var finalImage: UIImage?
    var imageSource = "unknown"

    if let attachment = attributes[.attachment] as? NSTextAttachment {
      if let image = attachment.image {
        finalImage = image
        imageSource = "attachment"
      }
    }

    if finalImage == nil,
       let adaptiveGlyph =
       attributes[NSAttributedString.Key(rawValue: "CTAdaptiveImageProvider")] as? NSObject
    {
      if let image = extractImageFromAdaptiveGlyph(adaptiveGlyph) {
        finalImage = image
        imageSource = "adaptive_glyph"
      }
    }

    if finalImage == nil, let pasteboardImage = UIPasteboard.general.image {
      finalImage = pasteboardImage
      imageSource = "pasteboard_direct"
    }

    if finalImage == nil {
      var glyphRect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)

      if glyphRect.width < 10 || glyphRect.height < 10 {
        glyphRect = CGRect(
          x: glyphRect.origin.x,
          y: glyphRect.origin.y,
          width: 200,
          height: 200
        )
      }

      let renderer = UIGraphicsImageRenderer(bounds: glyphRect)
      let image = renderer.image { context in
        UIColor.clear.setFill()
        context.fill(glyphRect)
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: -glyphRect.origin.x, y: -glyphRect.origin.y)
        self.layer.render(in: context.cgContext)
        context.cgContext.restoreGState()
      }

      finalImage = image
      imageSource = "rendered_glyph"
    }

    if let image = finalImage {
      var processedImage = image
      if image.size.width < 10 || image.size.height < 10 {
        let size = CGSize(width: 200, height: 200)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        image.draw(in: CGRect(origin: .zero, size: size))
        if let resizedImage = UIGraphicsGetImageFromCurrentImageContext() {
          processedImage = resizedImage
        }
        UIGraphicsEndImageContext()
      }

      if let imageData = processedImage.pngData() ?? processedImage
        .jpegData(compressionQuality: 0.9)
      {
        sendStickerImage(imageData, metadata: ["source": imageSource])
        safelyRemoveAttachment(at: range)
      } else {
        captureTextViewForDebug()
      }
    } else {
      captureTextViewForDebug()
    }
  }

  private func extractImageFromAdaptiveGlyph(_ adaptiveGlyph: NSObject) -> UIImage? {
    if adaptiveGlyph.responds(to: Selector(("imageContent"))) {
      if let imageContent = adaptiveGlyph.perform(Selector(("imageContent")))?
        .takeUnretainedValue()
      {
        if let image = imageContent as? UIImage {
          return image
        }

        if let contentObject = imageContent as? NSObject {
          if contentObject.responds(to: Selector(("image"))) {
            if let image = contentObject.value(forKey: "image") as? UIImage {
              return image
            }
          }
        }
      }
    }

    let singleParamMethods = [
      "imageForPointSize:",
      "imageAtSize:",
      "imageForSize:",
      "imageScaledToSize:",
      "renderImageWithSize:",
      "generateImageWithSize:",
      "imageWithScale:",
      "imageForScale:"
    ]

    let sizes = [
      CGSize(width: 200, height: 200),
      CGSize(width: 300, height: 300),
      CGSize(width: 100, height: 100),
      CGSize(width: 512, height: 512)
    ]

    for methodName in singleParamMethods {
      if adaptiveGlyph.responds(to: Selector((methodName))) {
        for size in sizes {
          if let result = adaptiveGlyph.perform(
            Selector((methodName)),
            with: NSValue(cgSize: size)
          )?
            .takeUnretainedValue()
          {
            if let image = result as? UIImage {
              return image
            }
          }

          if methodName.contains("Scale") {
            let scales: [CGFloat] = [1.0, 2.0, 3.0]
            for scale in scales {
              if let result = adaptiveGlyph.perform(
                Selector((methodName)),
                with: scale as NSNumber
              )?
                .takeUnretainedValue()
              {
                if let image = result as? UIImage {
                  return image
                }
              }
            }
          }
        }
      }
    }

    if adaptiveGlyph.responds(to: Selector(("nominalTextAttachment"))) {
      if let attachment = adaptiveGlyph.perform(Selector(("nominalTextAttachment")))
        .takeUnretainedValue() as? NSTextAttachment
      {
        if let image = attachment.image {
          return image
        }

        if let fileWrapper = attachment.fileWrapper,
           let data = fileWrapper.regularFileContents,
           let image = UIImage(data: data)
        {
          return image
        }
      }
    }

    if let pasteboardImage = UIPasteboard.general.image {
      return pasteboardImage
    }

    let propertyNames = [
      "image", "originalImage", "_image", "cachedImage", "renderedImage",
      "imageRepresentation", "imageValue", "displayImage", "previewImage",
      "thumbnailImage", "fullSizeImage", "scaledImage"
    ]

    for propertyName in propertyNames {
      if adaptiveGlyph.responds(to: Selector((propertyName))) {
        if let image = adaptiveGlyph.value(forKey: propertyName) as? UIImage {
          return image
        }
      }
    }

    var methodCount: UInt32 = 0
    let methodList = class_copyMethodList(object_getClass(adaptiveGlyph), &methodCount)
    if methodList != nil {
      for i in 0 ..< Int(methodCount) {
        if let method = methodList?[i] {
          let selector = method_getName(method)
        }
      }
      free(methodList)
    }

    return nil
  }

  private func captureTextViewForDebug() {
    let captureRect = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 300, height: 200) : bounds

    let renderer = UIGraphicsImageRenderer(bounds: captureRect)
    let image = renderer.image { context in
      UIColor.systemBackground.setFill()
      context.fill(captureRect)

      layer.render(in: context.cgContext)
    }

    if let data = image.pngData() {
      sendStickerImage(data, metadata: ["source": "debug_capture"])

      NotificationCenter.default.post(
        name: NSNotification.Name("DebugTextViewCapture"),
        object: nil,
        userInfo: ["image": image]
      )
    }
  }

  private func processAdaptiveImageProvider(_ provider: Any, range: NSRange) {
    var finalImage: UIImage?

    if let adaptiveGlyph = provider as? NSObject {
      if adaptiveGlyph.responds(to: Selector(("image"))) {
        if let image = adaptiveGlyph.value(forKey: "image") as? UIImage {
          finalImage = image
        }
      }
    }

    if finalImage == nil {
      let renderer = UIGraphicsImageRenderer(bounds: bounds)
      let image = renderer.image { context in
        context.cgContext.saveGState()

        let glyphRect = self.layoutManager.boundingRect(
          forGlyphRange: range,
          in: self.textContainer
        )
        context.cgContext.translateBy(x: -glyphRect.origin.x, y: -glyphRect.origin.y)

        self.layer.render(in: context.cgContext)

        context.cgContext.restoreGState()
      }

      finalImage = image
    }

    if finalImage == nil {
      if let pasteboardImage = UIPasteboard.general.image {
        finalImage = pasteboardImage
      }
    }

    guard let image = finalImage else {
      return
    }

    guard let imageData = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else {
      return
    }

    sendStickerImage(imageData, metadata: ["source": "adaptive_image_provider"])

    safelyRemoveAttachment(at: range)
  }

  private func sendStickerImage(_ imageData: Data, metadata: [String: Any]) {
    let imageHash = imageData.prefix(1_024).hashValue

    processingLock.lock()

    if recentlySentImageHashes.contains(imageHash) {
      processingLock.unlock()
      return
    }

    recentlySentImageHashes.insert(imageHash)
    processingLock.unlock()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.processingLock.lock()
      self?.recentlySentImageHashes.remove(imageHash)
      self?.processingLock.unlock()
    }

    if let originalImage = UIImage(data: imageData) {
      Task {
        guard let composeView = self.composeView else { return }

        // Use the actor with async/await
        let (optimizedImage, _) = await ImageProcessor.shared.processImage(originalImage)

        DispatchQueue.main.async {
          composeView.sendSticker(optimizedImage)
          self.fixFontSizeAfterStickerInsertion()
        }
      }
    }
  }

  private func removeAttachment(at range: NSRange) {
    safelyRemoveAttachment(at: range)
  }

  private func safelyRemoveAttachment(at range: NSRange) {
    guard let attributedString = attributedText?.mutableCopy() as? NSMutableAttributedString else {
      return
    }

    let validRange = NSRange(
      location: min(range.location, attributedString.length),
      length: min(range.length, max(0, attributedString.length - range.location))
    )

    if validRange.length > 0 {
      attributedString.replaceCharacters(in: validRange, with: "")
      attributedString.addAttribute(
        .font,
        value: UIFont.systemFont(ofSize: 17),
        range: NSRange(
          location: 0,
          length: attributedString.length
        )
      )

      DispatchQueue.main.async { [weak self] in
        self?.attributedText = attributedString
      }
    }
  }
}

extension ComposeTextView: UITextViewDelegate {
  func textViewDidBeginEditing(_ textView: UITextView) {}

  func textViewDidEndEditing(_ textView: UITextView) {}
}

extension ComposeTextView {
  public func checkForNewAttachmentsImmediate() {
    guard let attributedText else {
      return
    }

    var foundAttachments = false

    attributedText.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, range, stop in
      if let attachment = value as? NSTextAttachment {
        foundAttachments = true

        self.processTextAttachmentEnhanced(attachment, range: range)

        stop.pointee = true
      }
    }
  }

  private func processTextAttachmentEnhanced(_ attachment: NSTextAttachment, range: NSRange) {
    var finalImage: UIImage?
    var imageSource = "unknown"

    if let image = attachment.image {
      finalImage = image
      imageSource = "direct_image_property"
    } else if let fileWrapper = attachment.fileWrapper {
      if let data = fileWrapper.regularFileContents, let image = UIImage(data: data) {
        finalImage = image
        imageSource = "file_wrapper_data"
      }
    } else if #available(iOS 13.0, *) {
      if let image = attachment.image(
        forBounds: attachment.bounds,
        textContainer: textContainer,
        characterIndex: range.location
      ) {
        finalImage = image
        imageSource = "image_for_bounds"
      }
    }

    guard let image = finalImage else {
      return
    }

    let imageHash: Int
    if let imageData = image.pngData()?.prefix(1_024) {
      imageHash = imageData.hashValue
    } else {
      imageHash = image.description.hashValue
    }

    processingLock.lock()

    if recentlySentImageHashes.contains(imageHash) {
      processingLock.unlock()
      return
    }

    recentlySentImageHashes.insert(imageHash)
    processingLock.unlock()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.processingLock.lock()
      self?.recentlySentImageHashes.remove(imageHash)
      self?.processingLock.unlock()
    }

    safelyRemoveAttachment(at: range)

    if let composeView = composeView {
      Task {
        // Use the actor with async/await
        let (optimizedImage, _) = await ImageProcessor.shared.processImage(image)

        DispatchQueue.main.async {
          composeView.sendSticker(optimizedImage)
          self.fixFontSizeAfterStickerInsertion()
        }
      }
      return
    }

    NotificationCenter.default.post(
      name: NSNotification.Name("StickerDetected"),
      object: nil,
      userInfo: ["image": image]
    )
  }

  private func findEnhancedParentComposeView() -> ComposeView? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let composeView = nextResponder as? ComposeView {
        return composeView
      }
      responder = nextResponder
    }

    var currentView: UIView? = self
    while let superview = currentView?.superview {
      if let composeView = superview as? ComposeView {
        return composeView
      }
      currentView = superview
    }

    if let window, let rootViewController = window.rootViewController {
      var viewController: UIViewController? = rootViewController
      while let vc = viewController {
        if let composeView = vc.view.subviews
          .first(where: { $0 is ComposeView }) as? ComposeView
        {
          return composeView
        }
        viewController = vc.presentedViewController
      }
    }

    return nil
  }
}

extension UIImage {
  func isMainlyTransparent() -> Bool {
    guard let cgImage else { return true }

    let width = cgImage.width
    let height = cgImage.height

    if width < 10 || height < 10 {
      return true
    }

    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    let bitsPerComponent = 8

    var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
      data: &data,
      width: width,
      height: height,
      bitsPerComponent: bitsPerComponent,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else { return true }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let sampleSize = min(100, width * height)
    let strideLength = max(1, (width * height) / sampleSize)

    var nonTransparentCount = 0

    for i in stride(
      from: 0,
      to: width * height * bytesPerPixel,
      by: strideLength * bytesPerPixel
    ) {
      let alpha = data[i + 3]
      if alpha > 20 {
        nonTransparentCount += 1
      }
    }

    return nonTransparentCount < (sampleSize / 20)
  }
}
