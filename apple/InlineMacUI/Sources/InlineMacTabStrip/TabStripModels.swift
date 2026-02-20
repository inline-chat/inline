import Foundation

public enum TabStripItemStyle: Hashable, Sendable {
  case home
  case standard
}

public struct TabStripItem: Hashable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public var systemIconName: String?
  public var style: TabStripItemStyle
  public var isClosable: Bool

  public init(
    id: String,
    title: String,
    systemIconName: String? = nil,
    style: TabStripItemStyle = .standard,
    isClosable: Bool = true
  ) {
    self.id = id
    self.title = title
    self.systemIconName = systemIconName
    self.style = style
    self.isClosable = isClosable
  }
}
