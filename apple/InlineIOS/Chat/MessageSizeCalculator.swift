import Foundation
import InlineKit
import UIKit

final class MessageSizeCalculator {
  private var cachedSizes: [Int64: CGSize] = [:]
    
  struct Configuration {
    let maxWidth: CGFloat
    let font: UIFont
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
  }
    
  private let configuration: Configuration
    
  static let shared = MessageSizeCalculator(
    configuration: Configuration(
      maxWidth: UIScreen.main.bounds.width,
      font: .systemFont(ofSize: 16),
      horizontalPadding: 20, // 10 padding on each side
      verticalPadding: 16, // 8 padding on each side
      minHeight: 36
    )
  )
    
  private init(configuration: Configuration) {
    self.configuration = configuration
  }
    
  func size(for message: FullMessage, maxWidth: CGFloat) -> CGSize {
    if let cachedSize = cachedSizes[message.message.id] {
      return cachedSize
    }
        
    let availableWidth = maxWidth - configuration.horizontalPadding
        
    let text = message.message.text ?? ""
    let constraintRect = CGSize(
      width: availableWidth,
      height: .greatestFiniteMagnitude
    )
        
    let boundingBox = text.boundingRect(
      with: constraintRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: configuration.font],
      context: nil
    )
        
    let height = max(
      boundingBox.height + configuration.verticalPadding,
      configuration.minHeight
    )
        
    let finalSize = CGSize(
      width: maxWidth,
      height: height
    )
        
    cachedSizes[message.message.id] = finalSize
    return finalSize
  }
    
  func invalidateCache(for messageId: Int64? = nil) {
    if let messageId {
      cachedSizes.removeValue(forKey: messageId)
    } else {
      cachedSizes.removeAll(keepingCapacity: true)
    }
  }
}
