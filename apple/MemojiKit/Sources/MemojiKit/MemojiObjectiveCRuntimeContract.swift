import Foundation
import ObjectiveC.runtime

enum MemojiObjectiveCValueKind: Equatable, Sendable {
  case void
  case object
  case bool
  case unsignedInteger
  case cgFloat
  case size

  func accepts(_ rawEncoding: String) -> Bool {
    let encoding = rawEncoding.drop(while: Self.isQualifier)
    guard let first = encoding.first else { return false }

    switch self {
    case .void:
      return first == "v"
    case .object:
      return first == "@" || first == "#"
    case .bool:
      return first == "B" || first == "c"
    case .unsignedInteger:
      return "QILSC".contains(first)
    case .cgFloat:
      return first == "d"
    case .size:
      return encoding.hasPrefix("{CGSize=")
        || encoding.hasPrefix("{NSSize=")
        || encoding.hasPrefix("{_NSSize=")
    }
  }

  private static func isQualifier(_ character: Character) -> Bool {
    "rnNoORV".contains(character)
  }
}

struct MemojiObjectiveCMethodContract: Equatable, Sendable {
  let returnValue: MemojiObjectiveCValueKind
  let arguments: [MemojiObjectiveCValueKind]

  func matches(_ method: Method) -> Bool {
    guard method_getNumberOfArguments(method) == UInt32(arguments.count + 2),
          returnValue.accepts(Self.returnEncoding(of: method))
    else { return false }

    return arguments.enumerated().allSatisfy { offset, kind in
      kind.accepts(Self.argumentEncoding(of: method, at: UInt32(offset + 2)))
    }
  }

  private static func returnEncoding(of method: Method) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    method_getReturnType(method, &buffer, buffer.count)
    return decode(buffer)
  }

  private static func argumentEncoding(of method: Method, at index: UInt32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    method_getArgumentType(method, index, &buffer, buffer.count)
    return decode(buffer)
  }

  private static func decode(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8) ?? ""
  }
}
