import ObjectiveC // Add this import for class_copyMethodList
import UIKit
import UniformTypeIdentifiers

class ComposeTextView: UITextView {
  private var placeholderLabel: UILabel?
  private var lastText: String = ""

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupTextView()
    setupPlaceholder()
    setupNotifications()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupTextView() {
    backgroundColor = .clear
    isEditable = true
    allowsEditingTextAttributes = true
    delegate = self
    font = .systemFont(ofSize: 17)
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    translatesAutoresizingMaskIntoConstraints = false
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
      label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
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
      if let pasteboardImage = UIPasteboard.general.image {
        if let imageData = pasteboardImage.pngData() ?? pasteboardImage.jpegData(compressionQuality: 0.9) {
          DispatchQueue.main.async {
            self.sendStickerImage(imageData, metadata: ["source": "pasteboard_textDidChange"])

            if let range = self.text.range(of: "￼") {
              let nsRange = NSRange(range, in: self.text)
              self.removeAttachment(at: nsRange)
              return
            }
          }
        }
      }
      checkForNewAttachments()
    }

    lastText = text
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.checkForNewAttachments()
    }
  }

  func showPlaceholder(_ show: Bool) {
    placeholderLabel?.alpha = show ? 1 : 0
  }

  override func insertText(_ text: String) {
    super.insertText(text)

    if text.contains("￼") {
      checkForNewAttachments()
    }
  }

  private func findParentComposeView() -> ComposeView? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let composeView = nextResponder as? ComposeView {
        return composeView
      }
      responder = nextResponder
    }
    return nil
  }

  override func paste(_ sender: Any?) {
    // Check if there's an image on the pasteboard before pasting
    let pasteboard = UIPasteboard.general
    let hadImage = pasteboard.hasImages
    let originalImage = pasteboard.image

    // Perform the standard paste operation
    super.paste(sender)

    // If there was an image on the pasteboard, try to process it directly
    if hadImage, let image = originalImage {
      if let imageData = image.pngData() ?? image.jpegData(compressionQuality: 0.9) {
        // Process the image directly
        DispatchQueue.main.async {
          self.sendStickerImage(imageData, metadata: ["source": "direct_pasteboard"])

          // Remove the object replacement character if it was inserted
          if let range = self.text.range(of: "￼") {
            let nsRange = NSRange(range, in: self.text)
            self.removeAttachment(at: nsRange)
          }
        }

        // Return early since we've handled the image
        return
      }
    }

    // Still check for attachments as a fallback
    if text.contains("￼") || attributedText.string.contains("￼") {
      checkForNewAttachments()
    }
  }

  override var attributedText: NSAttributedString! {
    didSet {
      if attributedText?.string.contains("￼") == true {
        checkForNewAttachments()
      }
    }
  }

  public func checkForNewAttachments() {
    guard let attributedText else { return }

    let string = attributedText.string
    for (index, char) in string.enumerated() {
      if char == "\u{FFFC}" { // Object replacement character
        let nsRange = NSRange(location: index, length: 1)

        // Get attributes at this position
        let attributes = attributedText.attributes(at: index, effectiveRange: nil)

        // Try to process this position
        DispatchQueue.main.async {
          self.processReplacementCharacter(at: nsRange, attributes: attributes)
        }
      }
    }
  }

  private func processReplacementCharacter(at range: NSRange, attributes: [NSAttributedString.Key: Any]) {
    var finalImage: UIImage?
    var imageSource = "unknown"

    if let attachment = attributes[.attachment] as? NSTextAttachment {
      if let image = attachment.image {
        finalImage = image
        imageSource = "attachment"
      }
    }

    if finalImage == nil,
       let adaptiveGlyph = attributes[NSAttributedString.Key(rawValue: "CTAdaptiveImageProvider")] as? NSObject
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
        glyphRect = CGRect(x: glyphRect.origin.x, y: glyphRect.origin.y, width: 200, height: 200)
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

      if let imageData = processedImage.pngData() ?? processedImage.jpegData(compressionQuality: 0.9) {
        sendStickerImage(imageData, metadata: ["source": imageSource])
        removeAttachment(at: range)
      } else {
        captureTextViewForDebug()
      }
    } else {
      captureTextViewForDebug()
    }
  }

  private func extractImageFromAdaptiveGlyph(_ adaptiveGlyph: NSObject) -> UIImage? {
    // Try the specific methods we found in the logs

    // 1. Try imageContent method
    if adaptiveGlyph.responds(to: Selector(("imageContent"))) {
      if let imageContent = adaptiveGlyph.perform(Selector(("imageContent")))?.takeUnretainedValue() {
        // If imageContent is an image, use it directly
        if let image = imageContent as? UIImage {
          return image
        }

        // If imageContent is another object, try to get an image from it
        if let contentObject = imageContent as? NSObject {
          if contentObject.responds(to: Selector(("image"))) {
            if let image = contentObject.value(forKey: "image") as? UIImage {
              return image
            }
          }
        }
      }
    }

    // Try single parameter methods
    let singleParamMethods = [
      "imageForPointSize:",
      "imageAtSize:",
      "imageForSize:",
      "imageScaledToSize:",
      "renderImageWithSize:",
      "generateImageWithSize:",
      "imageWithScale:",
      "imageForScale:",
    ]

    let sizes = [
      CGSize(width: 200, height: 200),
      CGSize(width: 300, height: 300),
      CGSize(width: 100, height: 100),
      CGSize(width: 512, height: 512),
    ]

    // Try methods that take a single size parameter
    for methodName in singleParamMethods {
      if adaptiveGlyph.responds(to: Selector((methodName))) {
        for size in sizes {
          // Try with NSValue
          if let result = adaptiveGlyph.perform(Selector((methodName)), with: NSValue(cgSize: size))?
            .takeUnretainedValue()
          {
            if let image = result as? UIImage {
              print("✅ STICKER - Got image from \(methodName) with NSValue size: \(image.size)")
              return image
            }
          }

          // Try with NSNumber for methods that might take a scale
          if methodName.contains("Scale") {
            let scales: [CGFloat] = [1.0, 2.0, 3.0]
            for scale in scales {
              if let result = adaptiveGlyph.perform(Selector((methodName)), with: scale as NSNumber)?
                .takeUnretainedValue()
              {
                if let image = result as? UIImage {
                  print("✅ STICKER - Got image from \(methodName) with scale \(scale): \(image.size)")
                  return image
                }
              }
            }
          }
        }
      }
    }

    // 4. Try nominalTextAttachment
    if adaptiveGlyph.responds(to: Selector(("nominalTextAttachment"))) {
      if let attachment = adaptiveGlyph.perform(Selector(("nominalTextAttachment")))?
        .takeUnretainedValue() as? NSTextAttachment
      {
        print("✅ STICKER - Got nominalTextAttachment")

        if let image = attachment.image {
          print("✅ STICKER - Got image from nominalTextAttachment.image: \(image.size)")
          return image
        }

        if let fileWrapper = attachment.fileWrapper, let data = fileWrapper.regularFileContents,
           let image = UIImage(data: data)
        {
          print("✅ STICKER - Got image from nominalTextAttachment.fileWrapper: \(image.size)")
          return image
        }
      }
    }

    // 5. Try to directly access the pasteboard
    if let pasteboardImage = UIPasteboard.general.image {
      print("✅ STICKER - Retrieved image directly from pasteboard: \(pasteboardImage.size)")
      return pasteboardImage
    }

    // 6. Try the original property methods as fallback
    let propertyNames = [
      "image", "originalImage", "_image", "cachedImage", "renderedImage",
      "imageRepresentation", "imageValue", "displayImage", "previewImage",
      "thumbnailImage", "fullSizeImage", "scaledImage",
    ]

    for propertyName in propertyNames {
      if adaptiveGlyph.responds(to: Selector((propertyName))) {
        if let image = adaptiveGlyph.value(forKey: propertyName) as? UIImage {
          print("✅ STICKER - Extracted image via property: \(propertyName)")
          return image
        }
      }
    }

    // 7. Try to get information about the glyph to help with debugging
    print("🔍 STICKER - Dumping NSAdaptiveImageGlyph information:")

    // Get all methods the object responds to
    var methodCount: UInt32 = 0
    let methodList = class_copyMethodList(object_getClass(adaptiveGlyph), &methodCount)
    if methodList != nil {
      print("🔍 STICKER - NSAdaptiveImageGlyph responds to \(methodCount) methods:")
      for i in 0 ..< Int(methodCount) {
        if let method = methodList?[i] {
          let selector = method_getName(method)
          print("  - \(NSStringFromSelector(selector))")
        }
      }
      free(methodList)
    }

    print("❌ STICKER - Failed to extract image from NSAdaptiveImageGlyph")
    return nil
  }

  private func captureTextViewForDebug() {
    print("🔍 DEBUG - Capturing entire text view for analysis")

    // Make sure the text view has a reasonable size for capture
    let captureRect = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 300, height: 200) : bounds

    let renderer = UIGraphicsImageRenderer(bounds: captureRect)
    let image = renderer.image { context in
      // Fill with a light background to make content visible
      UIColor.systemBackground.setFill()
      context.fill(captureRect)

      // Render the text view
      layer.render(in: context.cgContext)
    }

    if let data = image.pngData() {
      print("🔍 DEBUG - Captured text view image: \(image.size), \(data.count) bytes")

      // Try to send this image as a fallback
      sendStickerImage(data, metadata: ["source": "debug_capture"])

      // Also post a notification with the debug image
      NotificationCenter.default.post(
        name: NSNotification.Name("DebugTextViewCapture"),
        object: nil,
        userInfo: ["image": image]
      )
    }
  }

  private func processAdaptiveImageProvider(_ provider: Any, range: NSRange) {
    print("🔍 STICKER - Processing adaptive image provider: \(provider)")

    // Try to extract image using various methods
    var finalImage: UIImage?

    // Method 1: Try to get image using reflection
    if let adaptiveGlyph = provider as? NSObject {
      // Try to access image property if it exists
      if adaptiveGlyph.responds(to: Selector(("image"))) {
        if let image = adaptiveGlyph.value(forKey: "image") as? UIImage {
          finalImage = image
          print("✅ STICKER - Got image from adaptive glyph via reflection")
        }
      }
    }

    // Method 2: Try to render the text view content at this range
    if finalImage == nil {
      let renderer = UIGraphicsImageRenderer(bounds: bounds)
      let image = renderer.image { context in
        // Save the current context state
        context.cgContext.saveGState()

        // Offset the context to only capture the relevant part
        let glyphRect = self.layoutManager.boundingRect(forGlyphRange: range, in: self.textContainer)
        context.cgContext.translateBy(x: -glyphRect.origin.x, y: -glyphRect.origin.y)

        // Render the text view
        self.layer.render(in: context.cgContext)

        // Restore the context state
        context.cgContext.restoreGState()
      }

      finalImage = image
      print("✅ STICKER - Created image by rendering text view content")
    }

    // Method 3: Try to access the pasteboard
    if finalImage == nil {
      if let pasteboardImage = UIPasteboard.general.image {
        finalImage = pasteboardImage
        print("✅ STICKER - Retrieved image from pasteboard")
      }
    }

    guard let image = finalImage else {
      print("❌ STICKER - Failed to extract image from adaptive image provider")
      return
    }

    // Process the image
    guard let imageData = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else {
      print("❌ STICKER - Failed to convert image to data")
      return
    }

    print("✅ STICKER - Ready to send sticker data (\(imageData.count) bytes)")
    sendStickerImage(imageData, metadata: ["source": "adaptive_image_provider"])

    removeAttachment(at: range)
  }

  private func sendStickerImage(_ imageData: Data, metadata: [String: Any]) {
    print("📤 SENDING - Sticker image with \(imageData.count) bytes")

    if let originalImage = UIImage(data: imageData) {
      print("📤 SENDING - Original image size: \(originalImage.size)")

      let maxDimension: CGFloat = 300

      var newSize = originalImage.size
      if newSize.width > maxDimension || newSize.height > maxDimension {
        if newSize.width > newSize.height {
          newSize.height = (newSize.height / newSize.width) * maxDimension
          newSize.width = maxDimension
        } else {
          newSize.width = (newSize.width / newSize.height) * maxDimension
          newSize.height = maxDimension
        }
      }

      // Create a resized image
      UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
      originalImage.draw(in: CGRect(origin: .zero, size: newSize))
      let resizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? originalImage
      UIGraphicsEndImageContext()

      print("📤 SENDING - Resized image to: \(resizedImage.size)")

      if let composeView = findParentComposeView() {
        print("📤 SENDING - Found parent ComposeView, sending sticker")

        DispatchQueue.main.async {
          composeView.sendSticker(resizedImage)
        }
      } else {
        print("❌ SENDING - Could not find parent ComposeView")

        var currentView: UIView? = self
        while let superview = currentView?.superview {
          if let composeView = superview as? ComposeView {
            DispatchQueue.main.async {
              composeView.sendSticker(resizedImage)
            }
            return
          }
          currentView = superview
        }

        print("📤 SENDING - Trying notification approach")
        NotificationCenter.default.post(
          name: NSNotification.Name("StickerDetected"),
          object: nil,
          userInfo: ["image": resizedImage]
        )
      }
    } else {
      print("❌ SENDING - Failed to convert sticker data to image")
    }
  }

  private func removeAttachment(at range: NSRange) {
    print("🔍 STICKER - Removing attachment at range: \(range)")

    guard let attributedString = attributedText?.mutableCopy() as? NSMutableAttributedString else {
      print("❌ STICKER - Failed to create mutable attributed string")
      return
    }

    attributedString.replaceCharacters(in: range, with: "")

    attributedText = attributedString

    print("✅ STICKER - Removed attachment from text")
  }
}

extension ComposeTextView: UITextViewDelegate {
  func textViewDidBeginEditing(_ textView: UITextView) {
    print("📱 DELEGATE - textViewDidBeginEditing")
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    print("📱 DELEGATE - textViewDidEndEditing")
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    print("📱 DELEGATE - shouldChangeTextIn: range=\(range), text=\(text.isEmpty ? "empty" : text)")

    if text.contains("￼") {
      print("🔍 STICKER - Detected object replacement character in shouldChangeTextIn")
      DispatchQueue.main.async {
        self.checkForNewAttachmentsImmediate()
      }
    }

    return true
  }
}

extension ComposeTextView {
  public func checkForNewAttachmentsImmediate() {
    print("🔍 STICKER - Checking for attachments (immediate)")
    guard let attributedText else {
      print("🔍 STICKER - No attributed text available")
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
        print("🔍 STICKER - Found attachment at range: \(range)")

        DispatchQueue.main.async {
          self.processTextAttachmentEnhanced(attachment, range: range)
        }

        stop.pointee = true
      }
    }

    if !foundAttachments {
      print("🔍 STICKER - No attachments found in text")
    }
  }

  private func processTextAttachmentEnhanced(_ attachment: NSTextAttachment, range: NSRange) {
    print("🔍 STICKER - Processing attachment at range: \(range) (enhanced)")

    var finalImage: UIImage?
    var imageSource = "unknown"

    if let image = attachment.image {
      finalImage = image
      imageSource = "direct_image_property"
      print("✅ STICKER - Got image from direct property: \(image.size)")
    } else if let fileWrapper = attachment.fileWrapper {
      print("🔍 STICKER - Examining fileWrapper: \(fileWrapper.preferredFilename ?? "unnamed")")

      if let data = fileWrapper.regularFileContents, let image = UIImage(data: data) {
        finalImage = image
        imageSource = "file_wrapper_data"
        print("✅ STICKER - Created image from fileWrapper data: \(image.size)")
      }
    } else if #available(iOS 13.0, *) {
      if let image = attachment.image(
        forBounds: attachment.bounds,
        textContainer: textContainer,
        characterIndex: range.location
      ) {
        finalImage = image
        imageSource = "image_for_bounds"
        print("✅ STICKER - Got image using image(forBounds:): \(image.size)")
      }
    }

    guard let image = finalImage else {
      print("❌ STICKER - Failed to extract image from attachment")
      return
    }

    removeAttachment(at: range)

    if let composeView = findEnhancedParentComposeView() {
      print("📤 SENDING - Found parent ComposeView (enhanced), sending sticker")
      DispatchQueue.main.async {
        composeView.sendSticker(image)
      }
      return
    }

    if let composeView = findParentComposeView() {
      print("📤 SENDING - Found parent ComposeView (original), sending sticker")
      DispatchQueue.main.async {
        composeView.sendSticker(image)
      }
      return
    }

    print("📤 SENDING - Using notification approach")
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
        if let composeView = vc.view.subviews.first(where: { $0 is ComposeView }) as? ComposeView {
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

    // If image is very small, consider it empty
    if width < 10 || height < 10 {
      return true
    }

    // Sample a few pixels to check for transparency
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

    // Draw the image into the context
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Check a sample of pixels for non-transparency
    let sampleSize = min(100, width * height)
    let strideLength = max(1, (width * height) / sampleSize)

    var nonTransparentCount = 0

    for i in stride(from: 0, to: width * height * bytesPerPixel, by: strideLength * bytesPerPixel) {
      let alpha = data[i + 3]
      if alpha > 20 { // Consider pixels with alpha > 20 as non-transparent
        nonTransparentCount += 1
      }
    }

    // If less than 5% of sampled pixels are non-transparent, consider it empty
    return nonTransparentCount < (sampleSize / 20)
  }
}
