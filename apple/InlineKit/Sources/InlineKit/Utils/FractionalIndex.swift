import Foundation

public enum FractionalIndex {
  private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
  private static let maxDigit = alphabet.count - 1
  private static let digitMap = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })

  public static func between(_ left: String?, _ right: String?) -> String {
    if let left, let right {
      precondition(left < right, "left fractional index must be lower than right")
    }

    let leftBytes = left.map { Array($0.utf8) }
    let rightBytes = right.map { Array($0.utf8) }
    var result: [UInt8] = []
    var position = 0

    while true {
      let leftDigit = digit(in: leftBytes, at: position, fallback: 0)
      let rightDigit = digit(in: rightBytes, at: position, fallback: maxDigit)

      if rightDigit - leftDigit > 1 {
        result.append(alphabet[(leftDigit + rightDigit) / 2])
        return String(decoding: result, as: UTF8.self)
      }

      result.append(alphabet[leftDigit])
      position += 1
    }
  }

  public static func before(_ first: String?) -> String {
    between(nil, first)
  }

  public static func after(_ last: String?) -> String {
    between(last, nil)
  }

  public static func sequence(count: Int) -> [String] {
    guard count > 0 else { return [] }

    var result: [String] = []
    var previous: String?

    for _ in 0..<count {
      let next = after(previous)
      result.append(next)
      previous = next
    }

    return result
  }

  private static func digit(in bytes: [UInt8]?, at position: Int, fallback: Int) -> Int {
    guard let bytes, position < bytes.count else {
      return fallback
    }

    guard let digit = digitMap[bytes[position]] else {
      preconditionFailure("invalid fractional index character")
    }

    return digit
  }
}

