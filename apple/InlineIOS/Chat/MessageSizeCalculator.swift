import Foundation
import InlineKit
import UIKit

final class MessageSizeCalculator {
  private var cachedSizes: [Int64: CGSize] = [:]
  private let textCache = NSCache<NSString, NSAttributedString>()

  struct Configuration {
    let maxWidth: CGFloat
    let font: UIFont
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let transitionPadding: CGFloat
  }

  private let configuration: Configuration

  init(configuration: Configuration) {
    self.configuration = configuration
  }

  static let shared = MessageSizeCalculator(
    configuration: Configuration(
      maxWidth: UIScreen.main.bounds.width,
      font: .systemFont(ofSize: 16),
      horizontalPadding: 20,
      verticalPadding: 16,
      minHeight: 36,
      transitionPadding: 24
    )
  )

  func size(for message: FullMessage, maxWidth: CGFloat, isTransition: Bool) -> CGSize {
    let cacheKey = "\(message.message.id)-\(maxWidth)-\(isTransition)" as NSString

    if let cachedSize = cachedSizes[message.message.id],
       abs(cachedSize.width - maxWidth) < 0.001
    {
      return cachedSize
    }

    let availableWidth = maxWidth - configuration.horizontalPadding - 60

    let text = message.message.text ?? ""
    let attributedString = textCache.object(forKey: cacheKey) ?? createAttributedString(text)
    textCache.setObject(attributedString, forKey: cacheKey)

    let boundingRect = attributedString.boundingRect(
      with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )

    let height = ceil(boundingRect.height)
    let baseHeight = max(height + configuration.verticalPadding, configuration.minHeight)
    let finalHeight = isTransition ? baseHeight + configuration.transitionPadding : baseHeight + 2

    let size = CGSize(width: maxWidth, height: finalHeight)
    cachedSizes[message.message.id] = size

    return size
  }

  private func createAttributedString(_ text: String) -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.lineSpacing = 2

    return NSAttributedString(
      string: text,
      attributes: [
        .font: configuration.font,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  func invalidateCache(for messageId: Int64? = nil) {
    if let messageId {
      cachedSizes.removeValue(forKey: messageId)
    } else {
      cachedSizes.removeAll()
    }
  }
}
