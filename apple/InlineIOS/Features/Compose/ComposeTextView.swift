import InlineKit
import Logger
import ObjectiveC
import UIKit
import UniformTypeIdentifiers

class ComposeTextView: UITextView {
  private var placeholderLabel: UILabel?
  weak var composeView: ComposeView?
  private var processedRanges = Set<String>()
  private var recentlySentImageHashes = Set<Int>()
  private let processingLock = NSLock()

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
  }

  private func setupTextView() {
    backgroundColor = .clear
    allowsEditingTextAttributes = true
    font = .systemFont(ofSize: 17)
    typingAttributes[.font] = font
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    translatesAutoresizingMaskIntoConstraints = false
    tintColor = ThemeManager.shared.selected.accent
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

  @objc public func textDidChange() {
    showPlaceholder(text.isEmpty)

    if text.contains("￼") || attributedText.string.contains("￼") {
      // Get the full context of the text
      let fullText = attributedText.string
      let components = fullText.components(separatedBy: "￼")

      let isLikelyVoiceToSpeech = components.count == 2 &&
        (components[0].isEmpty || components[1].isEmpty) &&
        !hasValidStickerAttributes()

      if !isLikelyVoiceToSpeech {
        // handleStickerDetection()
        checkForNewAttachments()
      }
    }

    fixFontSizeAfterStickerInsertion()
  }

  @objc private func keyboardWillShow(_ notification: Notification) {}

  func showPlaceholder(_ show: Bool) {
    placeholderLabel?.alpha = show ? 1 : 0
  }

  override func paste(_ sender: Any?) {
    if UIPasteboard.general.image != nil {
      composeView?.handlePastedImage()
    } else if let string = UIPasteboard.general.string {
      // Insert plain text only
      let range = selectedRange
      let newText = (text as NSString).replacingCharacters(in: range, with: string)
      text = newText
      // Reset attributes
      fixFontSizeAfterStickerInsertion()
      showPlaceholder(text.isEmpty)
      composeView?.updateHeight()
      if !text.isEmpty {
        composeView?.buttonAppear()
      }
    } else {
      super.paste(sender)
      fixFontSizeAfterStickerInsertion()
      showPlaceholder(text.isEmpty)
      composeView?.updateHeight()
      if !text.isEmpty {
        composeView?.buttonAppear()
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

  public func checkForNewAttachments() {
    guard let attributedText else { return }

    let string = attributedText.string
    var rangesToProcess: [NSRange] = []

    for (index, char) in string.enumerated() {
      if char == "\u{FFFC}" {
        let nsRange = NSRange(location: index, length: 1)
        rangesToProcess.append(nsRange)
      }
    }

    if !rangesToProcess.isEmpty {
      DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
        guard let self else { return }
        for range in rangesToProcess {
          if range.location < attributedText.length {
            let attributes = attributedText.attributes(
              at: range.location,
              effectiveRange: nil
            )
            processReplacementCharacter(at: range, attributes: attributes)
          }
        }
      }
    }
  }

  private func processReplacementCharacter(
    at range: NSRange,
    attributes: [NSAttributedString.Key: Any]
  ) {
    if !hasValidStickerAttributes() {
      return
    }

    let rangeIdentifier = "\(range.location):\(range.length):\(Date().timeIntervalSince1970)"

    processingLock.lock()
    if processedRanges.contains(rangeIdentifier) {
      processingLock.unlock()
      return
    }
    processedRanges.insert(rangeIdentifier)
    processingLock.unlock()

    // DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
    processingLock.lock()
    processedRanges.remove(rangeIdentifier)
    processingLock.unlock()
    // }

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
      }
    }
  }

  // ??? sending char as sticker bug
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
      "imageForScale:",
    ]

    let sizes = [
      CGSize(width: 200, height: 200),
      CGSize(width: 300, height: 300),
      CGSize(width: 100, height: 100),
      CGSize(width: 512, height: 512),
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

    let propertyNames = [
      "image", "originalImage", "_image", "cachedImage", "renderedImage",
      "imageRepresentation", "imageValue", "displayImage", "previewImage",
      "thumbnailImage", "fullSizeImage", "scaledImage",
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

  // ??? sending char as sticker bug
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

  private func sendStickerImage(_ imageData: Data, metadata: [String: Any]) {
    let imageHash = imageData.prefix(1_024).hashValue

    processingLock.lock()

    if recentlySentImageHashes.contains(imageHash) {
      processingLock.unlock()
      return
    }

    recentlySentImageHashes.insert(imageHash)
    processingLock.unlock()

    // DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
    processingLock.lock()
    recentlySentImageHashes.remove(imageHash)
    processingLock.unlock()
    // }

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

      DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
        self?.attributedText = attributedString
      }
    }
  }

  private func hasValidStickerAttributes() -> Bool {
    guard let attributedText else { return false }

    var hasValidSticker = false
    attributedText.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, _ in
      if let attachment = value as? NSTextAttachment {
        // Check if the attachment has valid image data
        if attachment.image != nil ||
          (attachment.fileWrapper?.regularFileContents != nil)
        {
          hasValidSticker = true
        }
      }
    }

    // Also check for adaptive glyph with image content
    attributedText.enumerateAttribute(
      NSAttributedString.Key(rawValue: "CTAdaptiveImageProvider"),
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, _ in
      if let adaptiveGlyph = value as? NSObject,
         adaptiveGlyph.responds(to: Selector(("imageContent")))
      {
        hasValidSticker = true
      }
    }

    return hasValidSticker
  }

  /// Override typing attributes setter to prevent unwanted bold inheritance
  override var typingAttributes: [NSAttributedString.Key: Any] {
    get {
      super.typingAttributes
    }
    set {
      Log.shared.debug("🎯 TYPING ATTRS SET: \(newValue)")

      // Check if we're trying to set bold attributes when we shouldn't
      if let font = newValue[.font] as? UIFont,
         font.fontDescriptor.symbolicTraits.contains(.traitBold)
      {
        Log.shared.debug("🎯 BOLD FONT DETECTED in typing attributes")

        // Only allow bold if we're actually in the MIDDLE of a bold region, not at the end
        let selectedRange = selectedRange
        var shouldAllowBold = false

        if selectedRange.length == 0, selectedRange.location > 0 {
          let checkPosition = selectedRange.location - 1
          if checkPosition < attributedText.length {
            let attributes = attributedText.attributes(at: checkPosition, effectiveRange: nil)
            let isPreviousCharBold = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits
              .contains(.traitBold) == true
            Log.shared.debug("🎯 Previous char is bold: \(isPreviousCharBold)")

            // CRITICAL FIX: Only allow bold if we're WITHIN a bold region
            // Check if the NEXT character is also bold (meaning we're in the middle)
            // If cursor is at the end of bold text, we should NOT inherit bold
            if isPreviousCharBold, selectedRange.location < attributedText.length {
              let nextAttributes = attributedText.attributes(at: selectedRange.location, effectiveRange: nil)
              let isNextCharBold = (nextAttributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits
                .contains(.traitBold) == true
              shouldAllowBold = isNextCharBold
              Log.shared.debug("🎯 Next char is bold: \(isNextCharBold), shouldAllowBold: \(shouldAllowBold)")
            } else {
              shouldAllowBold = false
              Log.shared.debug("🎯 Previous char not bold or at end, shouldAllowBold: false")
            }
          }
        }

        if !shouldAllowBold {
          Log.shared.debug("🛡️ BLOCKING bold typing attributes! Setting default instead.")
          let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.label,
          ]
          super.typingAttributes = defaultAttributes
          return
        } else {
          Log.shared.debug("🛡️ ALLOWING bold typing attributes (in middle of bold region)")
        }
      }

      super.typingAttributes = newValue
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
    } else {
      return
    }

    guard let image = finalImage else {
      return
    }

//    let imageHash: Int = if let imageData = image.pngData()?.prefix(1_024) {
//      imageData.hashValue
//    } else {
//      image.description.hashValue
//    }
//
//    processingLock.lock()
//
//    if recentlySentImageHashes.contains(imageHash) {
//      processingLock.unlock()
//      return
//    }
//
//    recentlySentImageHashes.insert(imageHash)
//    processingLock.unlock()
//
//    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
//      self?.processingLock.lock()
//      self?.recentlySentImageHashes.remove(imageHash)
//      self?.processingLock.unlock()
//    }

    safelyRemoveAttachment(at: range)

    if let composeView {
      Task(priority: .userInitiated) { @MainActor in
        // Use the actor with async/await
//        let (optimizedImage, _) = await ImageProcessor.shared.processImage(image)
//        composeView.sendSticker(optimizedImage)
        composeView.sendSticker(image)

        // ??
        self.fixFontSizeAfterStickerInsertion()
      }
      return
    }
    // not used
//    NotificationCenter.default.post(
//      name: NSNotification.Name("StickerDetected"),
//      object: nil,
//      userInfo: ["image": image]
//    )
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

// MARK: - UITextView Extensions for Mention Style Management

extension UITextView {
  /// Default attributes for this text view
  var defaultTypingAttributes: [NSAttributedString.Key: Any] {
    [
      .font: font ?? UIFont.systemFont(ofSize: 17),
      .foregroundColor: UIColor.label,
    ]
  }

  /// Check if cursor is positioned after a mention
  var isCursorAfterMention: Bool {
    let selectedRange = selectedRange
    guard selectedRange.length == 0, selectedRange.location > 0 else { return false }

    let checkPosition = selectedRange.location - 1
    guard checkPosition < attributedText.length else { return false }

    let attributes = attributedText.attributes(at: checkPosition, effectiveRange: nil)
    return attributes[.mentionUserId] != nil
  }

  /// Check if cursor is positioned after bold text
  var isCursorAfterBoldText: Bool {
    let selectedRange = selectedRange
    guard selectedRange.length == 0, selectedRange.location > 0 else { return false }

    let checkPosition = selectedRange.location - 1
    guard checkPosition < attributedText.length else { return false }

    let attributes = attributedText.attributes(at: checkPosition, effectiveRange: nil)
    if let font = attributes[.font] as? UIFont {
      return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }
    return false
  }

  /// Check if current typing attributes have mention styling
  var hasTypingAttributesMentionStyling: Bool {
    let currentTypingAttributes = typingAttributes
    return currentTypingAttributes[.mentionUserId] != nil ||
      (currentTypingAttributes[.foregroundColor] as? UIColor) == UIColor.systemBlue
  }

  /// Check if current typing attributes have bold styling
  var hasTypingAttributesBoldStyling: Bool {
    let currentTypingAttributes = typingAttributes
    if let font = currentTypingAttributes[.font] as? UIFont {
      return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }
    return false
  }

  /// Reset typing attributes to default to prevent style leakage
  func resetTypingAttributesToDefault() {
    let defaultAttributes: [NSAttributedString.Key: Any] = [
      .font: font ?? UIFont.systemFont(ofSize: 17),
      .foregroundColor: UIColor.label,
    ]

    // Set typing attributes
    typingAttributes = defaultAttributes

    // If there's selected text, ensure it also gets the default attributes
    let selectedRange = selectedRange
    if selectedRange.length == 0, selectedRange.location > 0 {
      // For cursor position, we just set typing attributes
      typingAttributes = defaultAttributes
    }
  }

  /// Update typing attributes based on cursor position to prevent style leakage
  func updateTypingAttributesIfNeeded() {
    let selectedRange = selectedRange

    // If cursor is after a mention/bold text or typing attributes have special styling, reset to default
    if selectedRange.length == 0,
       isCursorAfterMention || isCursorAfterBoldText || hasTypingAttributesMentionStyling ||
       hasTypingAttributesBoldStyling
    {
      resetTypingAttributesToDefault()
    }
  }
}
