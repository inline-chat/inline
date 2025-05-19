import Foundation
import GRDB
import InlineProtocol

public struct ApiSpace: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  @unchecked Sendable
{
  // Min
  public var id: Int64
  public var name: String
  public var date: Int

  // Extra
  public var creator: Bool?
}

public struct Space: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, @unchecked
Sendable {
  public var id: Int64

  // Space name
  public var name: String

  public var date: Date

  // Are we creator of the space?
  public var creator: Bool?

  // Based on https://github.com/groue/GRDB.swift/discussions/1492, GRDB models can't be marked as sendable in GRDB < 6
  // so we should use  . This issue was fixed in GRDB 7, but because we use GRDB + SQLCipher from Duck Duck Go, we can't
  // upgrade GRDB from v 6 to 7, and the discussions and issues are not open.
  public static let members = hasMany(Member.self)
  public static let users = hasMany(User.self, through: members, using: Member.user)

  public var users: QueryInterfaceRequest<User> {
    request(for: Space.users)
  }

  public var members: QueryInterfaceRequest<Member> {
    request(for: Space.members)
  }

  public static let chats = hasMany(Chat.self)
  public var chats: QueryInterfaceRequest<Chat> {
    request(for: Space.chats)
  }

  /// NOTE(@mo): `Int64.random(in: 1 ... 5000)` using this is dangerous because it can generate the same number for
  /// different spaces, and it will cause a conflict with the API.
  public init(
    id: Int64 = Int64.random(in: 1 ... 5_000), name: String, date: Date, creator: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.date = date
    self.creator = creator
  }
}

public extension Space {
  init(from apiSpace: ApiSpace) {
    id = apiSpace.id
    name = apiSpace.name
    creator = apiSpace.creator
    date = Self.fromTimestamp(from: apiSpace.date)
  }

  init(from: InlineProtocol.Space) {
    id = from.id
    name = from.name
    creator = from.creator
    date = Date(timeIntervalSince1970: Double(from.date))
  }

  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from) / 1_000)
  }
}

public extension Space {
  var nameWithoutEmoji: String {
    filterEmojiFromStart(name)
  }

  var displayName: String {
    nameWithoutEmoji.isEmpty ? "Untitled Space" : nameWithoutEmoji
  }

  func filterEmojiFromStart(_ text: String) -> String {
    guard let firstChar = text.first else { return text }

    if String(firstChar).containsEmoji {
      let withoutEmoji = String(text.dropFirst())

      if withoutEmoji.first == " " {
        return String(withoutEmoji.dropFirst())
      }
      return withoutEmoji
    }

    return text
  }
}

extension String {
  var containsEmoji: Bool {
    for scalar in unicodeScalars {
      switch scalar.value {
        case 0x1_F600 ... 0x1_F64F, // Emoticons
             0x1_F300 ... 0x1_F5FF, // Misc Symbols and Pictographs
             0x1_F680 ... 0x1_F6FF, // Transport and Map
             0x1_F700 ... 0x1_F77F, // Alchemical Symbols
             0x1_F780 ... 0x1_F7FF, // Geometric Shapes
             0x1_F800 ... 0x1_F8FF, // Supplemental Arrows-C
             0x1_F900 ... 0x1_F9FF, // Supplemental Symbols and Pictographs
             0x1_FA00 ... 0x1_FA6F, // Chess Symbols
             0x1_FA70 ... 0x1_FAFF, // Symbols and Pictographs Extended-A
             0x2600 ... 0x26FF, // Miscellaneous Symbols
             0x2700 ... 0x27BF, // Dingbats
             0x2300 ... 0x23FF, // Miscellaneous Technical
             0x2B00 ... 0x2BFF, // Miscellaneous Symbols and Arrows
             0x3000 ... 0x303F, // CJK Symbols and Punctuation
             0x3200 ... 0x32FF: // Enclosed CJK Letters and Months
          return true
        default:
          continue
      }
    }
    return false
  }
}
