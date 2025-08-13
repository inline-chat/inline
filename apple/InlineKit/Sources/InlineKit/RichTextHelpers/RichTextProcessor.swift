import Foundation
import InlineProtocol

/// Protocol for rich text pattern processors
public protocol RichTextPatternProcessor: Sendable {
  /// The entity type this processor handles
  static var entityType: MessageEntity.TypeEnum { get }
  
  /// Process patterns in attributed text and apply formatting
  /// - Parameters:
  ///   - attributedText: The input attributed text
  ///   - outgoing: Whether this is for an outgoing message
  /// - Returns: Processed attributed text with formatting applied
  func processPatterns(in attributedText: NSAttributedString, outgoing: Bool) -> NSAttributedString
  
  /// Extract entities from attributed text for protocol buffer transmission
  /// - Parameter attributedText: The attributed text to extract from
  /// - Returns: Array of message entities
  func extractEntities(from attributedText: NSAttributedString) -> [MessageEntity]
}

/// Centralized rich text processing coordinator
public class RichTextProcessor {
  
  // MARK: - Registered Processors
  
  private nonisolated(unsafe) static let processors: [any RichTextPatternProcessor] = [
    BoldTextProcessor(),
    InlineCodeProcessor()
  ]
  
  // MARK: - Public Interface
  
  /// Process all rich text patterns in attributed text
  /// - Parameters:
  ///   - attributedText: Input attributed text
  ///   - outgoing: Whether this is for an outgoing message
  /// - Returns: Fully processed attributed text
  public static func processAllPatterns(in attributedText: NSAttributedString, outgoing: Bool = false) -> NSAttributedString {
    var result = attributedText
    
    // Apply each processor in sequence
    for processor in processors {
      result = processor.processPatterns(in: result, outgoing: outgoing)
    }
    
    return result
  }
  
  /// Extract all entities from attributed text
  /// - Parameter attributedText: The attributed text
  /// - Returns: Combined array of all extracted entities
  public static func extractAllEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    var allEntities: [MessageEntity] = []
    
    for processor in processors {
      let entities = processor.extractEntities(from: attributedText)
      allEntities.append(contentsOf: entities)
    }
    
    // Sort entities by offset for consistent ordering
    return allEntities.sorted { $0.offset < $1.offset }
  }
}

// MARK: - Concrete Processors

/// Bold text pattern processor
private struct BoldTextProcessor: RichTextPatternProcessor {
  static let entityType = MessageEntity.TypeEnum.bold
  
  func processPatterns(in attributedText: NSAttributedString, outgoing: Bool) -> NSAttributedString {
    let detector = BoldTextDetector()
    return detector.processBoldText(in: attributedText)
  }
  
  func extractEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    // Bold entity extraction logic would go here
    // For now, return empty array as this is handled elsewhere
    return []
  }
}

/// Inline code pattern processor
private struct InlineCodeProcessor: RichTextPatternProcessor {
  static let entityType = MessageEntity.TypeEnum.code
  
  func processPatterns(in attributedText: NSAttributedString, outgoing: Bool) -> NSAttributedString {
    let detector = InlineCodeDetector()
    return detector.processInlineCode(in: attributedText, outgoing: outgoing)
  }
  
  func extractEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    // Inline code entity extraction logic would go here
    // For now, return empty array as this is handled elsewhere
    return []
  }
}
