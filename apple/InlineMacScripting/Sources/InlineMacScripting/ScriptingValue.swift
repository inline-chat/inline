import Foundation

/// Only these explicitly projected values cross the automation boundary. No KVC model graph.
public indirect enum ScriptingValue: Equatable, Sendable {
  case text(String)
  case integer(Int32)
  case boolean(Bool)
  case seconds(Double)
  case list([ScriptingValue])
  case record([ScriptingField: ScriptingValue])
  case missing

  // NSScriptCommand coerces replies according to the sdef's declared result type.
  // Scalars/lists must be Cocoa values; records use an explicit conversion hook
  // to preserve the dictionary's four-character property codes without KVC models.
  func cocoaValue() -> Any {
    switch self {
    case let .text(value): return value as NSString
    case let .integer(value): return NSNumber(value: value)
    case let .boolean(value): return NSNumber(value: value)
    case let .seconds(value): return NSNumber(value: value)
    case let .list(values): return values.map { $0.cocoaValue() } as NSArray
    case .record, .missing: return ScriptingDescriptorValue(descriptor())
    }
  }

  func descriptor() -> NSAppleEventDescriptor {
    switch self {
    case let .text(value): return NSAppleEventDescriptor(string: value)
    case let .integer(value): return NSAppleEventDescriptor(int32: value)
    case let .boolean(value): return NSAppleEventDescriptor(boolean: value)
    case let .seconds(value): return NSAppleEventDescriptor(double: value)
    case let .list(values):
      let result = NSAppleEventDescriptor.list()
      for (index, value) in values.enumerated() { result.insert(value.descriptor(), at: index + 1) }
      return result
    case let .record(fields):
      let result = NSAppleEventDescriptor.record()
      for (field, value) in fields { result.setDescriptor(value.descriptor(), forKeyword: fourCC(field.rawValue)) }
      return result
    case .missing: return NSAppleEventDescriptor(typeCode: fourCC("msng"))
    }
  }
}

private final class ScriptingDescriptorValue: NSObject {
  private let value: NSAppleEventDescriptor

  init(_ value: NSAppleEventDescriptor) { self.value = value }

  @objc func scriptingRecordDescriptor() -> NSAppleEventDescriptor { value }
  @objc func scriptingAnyDescriptor() -> NSAppleEventDescriptor { value }
}

public enum ScriptingField: String, Sendable {
  case userID = "Iuid"
  case displayName = "Inam"
  case username = "Iusr"
  case isBot = "Ibot"
  case spaceID = "Isid"
  case chatID = "Icid"
  case title = "Itit"
  case kind = "Iknd"
  case unreadCount = "Iunr"
  case messageID = "Imid"
  case senderID = "Ifrm"
  case text = "Itxt"
  case sentAt = "Idat"
  case outgoing = "Iout"
  case requestID = "Irid"
}
