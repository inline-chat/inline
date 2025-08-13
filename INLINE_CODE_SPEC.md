# Inline Code Feature Specification

## Overview

This specification outlines the implementation of inline code formatting in the Inline chat app, similar to existing **bold** text and @mention features. Users can format text with backticks (\`) to create inline code spans that are visually distinct from regular text.

## User Experience

### Input Pattern
- Users type backticks around text: `code here`
- Similar to bold text (`**text**`), backticks are processed and removed, leaving styled text
- Single backtick pairs create inline code spans
- Code spans are escaped/cleared when user presses Enter (similar to bold text escape behavior)

### Visual Design
- **Background**: Rounded rectangle background with corner radius
- **Colors**: 
  - **Outgoing messages**: Semi-transparent white background with white text
  - **Incoming messages**: Theme accent color background with contrasting text
- **Typography**: Monospace font (SF Mono on Apple platforms)
- **Padding**: Small internal padding around text content

## Technical Implementation

### 1. Shared Module Structure

Follow the existing pattern established by `BoldTextDetector` and `MentionDetector` in the `RichTextHelpers` module:

#### File Location
```
apple/InlineKit/Sources/InlineKit/RichTextHelpers/InlineCodeDetector.swift
```

#### Core Components
```swift
public struct InlineCodeRange {
  public let range: NSRange
  public let contentRange: NSRange // Range without backtick markers
  public let content: String
}

public class InlineCodeDetector {
  // Detection and processing logic
}
```

### 2. Pattern Detection

#### Regex Pattern
```regex
`([^`\n]+?)`
```
- Matches single backticks with content between them
- Non-greedy matching to handle multiple code spans in one message
- Excludes newlines within code spans (inline only)
- Prevents nested backticks

#### Detection Logic
- Process in reverse order to maintain correct string indices during replacement
- Extract content between backticks
- Remove backtick markers and apply formatting attributes

### 3. Styling Implementation

#### Background Styling
```swift
private func createInlineCodeAttributes(
  from existingAttributes: [NSAttributedString.Key: Any],
  outgoing: Bool
) -> [NSAttributedString.Key: Any] {
  var attributes = existingAttributes
  
  // Monospace font
  #if os(macOS)
  attributes[.font] = NSFont.monospacedSystemFont(ofSize: existingFont.pointSize, weight: .regular)
  #elseif os(iOS)
  attributes[.font] = UIFont.monospacedSystemFont(ofSize: existingFont.pointSize, weight: .regular)
  #endif
  
  // Background color with corner radius
  let backgroundColor = inlineCodeBackgroundColor(outgoing: outgoing)
  attributes[.backgroundColor] = backgroundColor
  
  // Text color
  let textColor = inlineCodeTextColor(outgoing: outgoing)
  attributes[.foregroundColor] = textColor
  
  return attributes
}
```

#### Color Scheme Integration
```swift
private func inlineCodeBackgroundColor(outgoing: Bool) -> UIColor {
  if outgoing {
    // Semi-transparent white for outgoing messages
    return UIColor.white.withAlphaComponent(0.2)
  } else {
    // Use theme accent color with transparency for incoming
    return ThemeManager.shared.selected.accent.withAlphaComponent(0.15)
  }
}

private func inlineCodeTextColor(outgoing: Bool) -> UIColor {
  if outgoing {
    return UIColor.white
  } else {
    return ThemeManager.shared.selected.primaryTextColor ?? .label
  }
}
```

### 4. Corner Radius Implementation

Since NSAttributedString doesn't natively support corner radius, implement using custom drawing or text attachments:

#### Option A: Custom Text Attachment
```swift
class InlineCodeTextAttachment: NSTextAttachment {
  let cornerRadius: CGFloat = 4.0
  let padding = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
  
  override func attachmentBounds(for textContainer: NSTextContainer?, 
                               proposedLineFragment lineFrag: CGRect, 
                               glyphPosition position: CGPoint, 
                               characterIndex charIndex: Int) -> CGRect {
    // Calculate bounds with padding
  }
}
```

#### Option B: Custom UILabel Subclass (iOS)
For iOS message rendering, create custom label handling for code spans with rounded backgrounds.

### 5. Escape Behavior

#### Enter Key Handling
Similar to bold text escape behavior:

```swift
public func shouldEscapeInlineCode(at cursorPosition: Int, 
                                 in attributedText: NSAttributedString) -> Bool {
  // Check if cursor is within an active code span
  // Return true if code formatting should be cleared
}

public func escapeInlineCode(in attributedText: NSAttributedString, 
                           at cursorPosition: Int) -> NSAttributedString {
  // Remove code formatting at cursor position
  // Convert styled code back to `code` format for continued editing
}
```

#### Implementation Notes
- When user presses Enter within a code span, convert styled text back to backtick format
- Clear formatting similar to how bold text handles escape behavior
- Maintain cursor position appropriately after escape

### 6. Integration Points

#### Text Processing Pipeline
Integrate with existing text processing in `TextProcessing` module:

```swift
// In message composition flow
let processedText = attributedText
  .processBoldText() // Existing
  .processInlineCode() // New
  .processMentions() // Existing
```

#### Message Rendering
Update `MessageRichTextRenderer` to handle code spans:

```swift
static func inlineCodeColor(for outgoing: Bool) -> UIColor {
  // Return appropriate color based on message direction
}

static func inlineCodeBackgroundColor(for outgoing: Bool) -> UIColor {
  // Return appropriate background color
}
```

### 7. Protocol Buffer Support

If code spans need to be preserved as entities in the protocol:

```protobuf
// In core.proto
enum MessageEntityType {
  // ... existing types
  INLINE_CODE = 4;
}

message MessageEntity {
  MessageEntityType type = 1;
  int32 offset = 2;
  int32 length = 3;
  // Additional fields as needed
}
```

## Implementation Phases

### Phase 1: Core Detection
- Implement `InlineCodeDetector` class
- Basic pattern matching and text replacement
- Unit tests for detection logic

### Phase 2: Visual Styling
- Implement monospace font application
- Basic background color support
- Integration with theme system

### Phase 3: Advanced Styling
- Corner radius implementation
- Proper padding and spacing
- Cross-platform consistency (iOS/macOS)

### Phase 4: Interaction Behavior
- Enter key escape behavior
- Cursor handling within code spans
- Edge case handling (empty spans, nested patterns)

### Phase 5: Integration & Testing
- Message composition integration
- Rendering pipeline integration
- Comprehensive testing across themes
- Performance optimization

## Design Considerations

### Performance
- Minimal impact on text processing pipeline
- Efficient regex pattern matching
- Lazy evaluation of styling attributes

### Accessibility
- Maintain text accessibility for screen readers
- Proper semantic marking of code content
- Voice control compatibility

### Theme Compatibility
- Work seamlessly with all existing themes
- Respect light/dark mode preferences
- Maintain visual hierarchy and contrast ratios

### Edge Cases
- Empty code spans: `''` - should be ignored
- Malformed patterns: `code`` or ``code` - should not match
- Newlines within spans: prevented by regex
- Multiple consecutive spans: `code1` `code2` - should work correctly
- Mixed formatting: `**bold `code` text**` - define precedence rules

## Testing Requirements

### Unit Tests
- Pattern detection accuracy
- Attribute application correctness
- Edge case handling
- Cross-platform font consistency

### Integration Tests
- Message composition flow
- Theme switching behavior
- Rendering across different message types
- Performance with long messages containing many code spans

### UI Tests
- Visual appearance across themes
- User interaction flows
- Accessibility compliance
- Cross-device consistency

## Success Criteria

1. **Functional**: Users can create inline code spans using backtick syntax
2. **Visual**: Code spans have distinct monospace font and themed backgrounds
3. **Consistent**: Behavior matches existing bold and mention patterns
4. **Performant**: No noticeable impact on typing or message rendering performance
5. **Accessible**: Feature works with assistive technologies
6. **Robust**: Handles edge cases gracefully without crashes or corruption

This specification provides a comprehensive roadmap for implementing inline code functionality while maintaining consistency with the existing Inline chat app architecture and design patterns.