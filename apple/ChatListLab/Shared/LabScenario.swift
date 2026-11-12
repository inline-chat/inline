import Foundation
import ChatListCore

/// All state below belongs to this fixture. ChatList owns positioning,
/// virtualization, animation, and native scroll compensation.
struct LabContent: Sendable {
  let id: Int64
  let revision: UInt64
  let title: String
  let text: String
  let expanded: Bool
  let headerText: String?
}

enum LabOperation: Equatable, CustomStringConvertible {
  case prepend, append, delete, toggleHeight, topInset, bottomInset, heightAndInset, resizeWidth

  var description: String {
    switch self {
    case .prepend: "prepend"
    case .append: "append"
    case .delete: "delete"
    case .toggleHeight: "height"
    case .topInset: "top inset"
    case .bottomInset: "bottom inset"
    case .heightAndInset: "height + insets"
    case .resizeWidth: "width"
    }
  }
}

struct LabRecord {
  private static let paragraph = "A native text view makes this row selectable. عربى עברית हिन्दी 中文 emoji 👨🏽‍💻. "
  private static let shortText = String(repeating: paragraph, count: 5)
  private static let longText = String(repeating: paragraph, count: 11)
  private static let hugeText = String(
    repeating: paragraph + paragraph + paragraph + paragraph, count: 150
  )

  let id: Int64
  var revision: UInt64 = 0
  var expanded = false
  var isLongPassage = false
  var bodyTop: CGFloat { isLongPassage && expanded ? 99 : 29 }

  var height: CGFloat {
    if isLongPassage { return expanded ? 5_240 : 5_000 }
    let baseline = CGFloat(132 + Int(abs(id) % 5) * 18)
    return baseline + (expanded ? 184 : 0)
  }

  var content: LabContent {
    return .init(
      id: id, revision: revision, title: "Message \(id) · revision \(revision)",
      text: isLongPassage ? Self.hugeText : (expanded ? Self.longText : Self.shortText),
      expanded: expanded,
      headerText: isLongPassage && expanded ? "Preceding child expanded above the same passage" : nil
    )
  }
}

struct LabScenario {
  static let maximumWindowCount = 720
  private(set) var records: [LabRecord]
  private var nextOlder: Int64 = -1
  private var nextNewer: Int64
  private(set) var topInset: CGFloat = 0
  private(set) var bottomInset: CGFloat = 0
  private(set) var eventCount = 0

  init(initialCount: Int = 360, includeLongPassage: Bool = false) {
    records = (0 ..< initialCount).map { value in
      var record = LabRecord(id: Int64(value))
      record.isLongPassage = includeLongPassage && value == 180
      return record
    }
    nextNewer = Int64(initialCount)
  }

  var ids: [Int64] { records.map(\.id) }

  /// Move a record after a list reorder drop.
  mutating func move(_ id: Int64, to index: Int) {
    guard let from = records.firstIndex(where: { $0.id == id }) else { return }
    let record = records.remove(at: from)
    records.insert(record, at: min(max(0, index), records.count))
  }

  /// A complete prepared snapshot; widths and all child frames are inputs to
  /// ChatList, so cells never ask the list to measure them during presentation.
  func snapshot(width: CGFloat, scale: CGFloat, environmentRevision: UInt64 = 0) -> ChatListSnapshot<Int64, LabContent> {
    let availableWidth = max(1, width)
    let bodyWidth = max(1, availableWidth - 36)
    let groups = stride(from: 0, to: records.count, by: 12).compactMap { start -> [ChatListDecoration<Int64>]? in
      guard records.indices.contains(start) else { return nil }
      let last = records[min(start + 11, records.count - 1)]
      let first = records[start]
      return [
        .init(id: "badge-\(first.id)", firstRow: first.id, lastRow: last.id,
              edge: .top, x: max(0, availableWidth - 112),
              size: CGSize(width: 100, height: 22), inset: 5),
        .init(id: "avatar-\(first.id)", firstRow: first.id, lastRow: last.id,
              edge: .bottom, x: 4, size: CGSize(width: 28, height: 28), inset: 4),
      ]
    }.flatMap { $0 }
    return ChatListSnapshot(
      context: .init(width: availableWidth, displayScale: max(1, scale), environmentRevision: environmentRevision),
      items: records.map { record in
        let body = CGRect(x: 18, y: record.bodyTop, width: bodyWidth,
                          height: max(1, record.height - record.bodyTop - 27))
        var elements = ["body": body]
        if record.isLongPassage, record.expanded {
          elements["header"] = CGRect(x: 18, y: 29, width: bodyWidth, height: 66)
        }
        return ChatListItem(
          id: record.id, revision: record.revision, reuseIdentifier: "native-text",
          content: record.content, height: record.height,
          elements: elements
        )
      },
      history: .init(hasOlder: true, hasNewer: false, isAtLiveEnd: true),
      decorations: groups
    )
  }

  /// The caller selects a currently visible row for mutations where it matters.
  mutating func perform(_ operation: LabOperation, visibleID: Int64? = nil) {
    eventCount += 1
    switch operation {
    case .prepend:
      let new = (0 ..< 4).map { offset in LabRecord(id: nextOlder - Int64(offset)) }
      records.insert(contentsOf: new.reversed(), at: 0)
      nextOlder -= 4
      if records.count > Self.maximumWindowCount {
        records.removeLast(records.count - Self.maximumWindowCount)
      }
    case .append:
      records.append(contentsOf: (0 ..< 3).map { offset in LabRecord(id: nextNewer + Int64(offset)) })
      nextNewer += 3
      if records.count > Self.maximumWindowCount {
        records.removeFirst(records.count - Self.maximumWindowCount)
      }
    case .delete:
      guard records.count > 30 else { break }
      let candidate = visibleID.flatMap { id in records.firstIndex(where: { $0.id == id }) }
      let index = candidate ?? records.count / 2
      records.remove(at: index)
    case .toggleHeight:
      let candidate = visibleID.flatMap { id in records.firstIndex(where: { $0.id == id }) }
      let index = candidate ?? records.count / 2
      records[index].expanded.toggle()
      records[index].revision &+= 1
    case .topInset:
      topInset = topInset == 0 ? 76 : 0
    case .bottomInset:
      bottomInset = bottomInset == 0 ? 92 : 0
    case .heightAndInset:
      let candidate = visibleID.flatMap { id in records.firstIndex(where: { $0.id == id }) }
      let index = candidate ?? records.count / 2
      records[index].expanded.toggle()
      records[index].revision &+= 1
      topInset = topInset == 0 ? 76 : 0
      bottomInset = bottomInset == 0 ? 92 : 0
    case .resizeWidth:
      break
    }
  }
}

struct LabReplay {
  private var state: UInt64 = 0x5741_4c4b_5445_5354

  mutating func next() -> LabOperation {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return switch Int((state >> 32) % 14) {
    case 0, 1, 2: .prepend
    case 3, 4: .append
    case 5, 6: .delete
    case 7, 8, 9: .toggleHeight
    case 10: .topInset
    case 11: .bottomInset
    case 12: .heightAndInset
    default: .resizeWidth
    }
  }
}
