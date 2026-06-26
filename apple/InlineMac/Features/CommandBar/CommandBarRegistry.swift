import AppKit
import Observation
import SwiftUI

struct CommandBarItem: Identifiable, Hashable {
  let id: String
  let title: String
  let systemImage: String
  let keywords: [String]
  let typeLabel: String
  let priority: Int
  let isEnabled: Bool

  init(
    id: String,
    title: String,
    systemImage: String,
    keywords: [String] = [],
    typeLabel: String = "Command",
    priority: Int = 0,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.keywords = keywords
    self.typeLabel = typeLabel
    self.priority = priority
    self.isEnabled = isEnabled
  }
}

struct CommandBarAction {
  let id: String
  let title: String
  let systemImage: String
  let keywords: [String]
  let typeLabel: String
  let priority: Int
  let isEnabled: Bool

  private let handler: CommandBarHandler

  init(
    _ title: String,
    systemImage: String,
    id: String? = nil,
    keywords: [String] = [],
    typeLabel: String = "Command",
    priority: Int = 0,
    isEnabled: Bool = true,
    perform: @escaping @MainActor () -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.systemImage = systemImage
    self.keywords = keywords
    self.typeLabel = typeLabel
    self.priority = priority
    self.isEnabled = isEnabled
    handler = CommandBarHandler(perform)
  }

  fileprivate func item(globalId: String) -> CommandBarItem {
    CommandBarItem(
      id: globalId,
      title: title,
      systemImage: systemImage,
      keywords: keywords,
      typeLabel: typeLabel,
      priority: priority,
      isEnabled: isEnabled
    )
  }

  @MainActor
  fileprivate func perform() {
    handler.perform()
  }
}

private final class CommandBarHandler {
  private let body: @MainActor () -> Void

  init(_ body: @escaping @MainActor () -> Void) {
    self.body = body
  }

  @MainActor
  func perform() {
    body()
  }
}

private struct RegisteredCommandBarAction {
  let item: CommandBarItem
  let action: CommandBarAction
}

@resultBuilder
enum CommandBarBuilder {
  static func buildBlock(_ components: [CommandBarAction]...) -> [CommandBarAction] {
    components.flatMap { $0 }
  }

  static func buildExpression(_ expression: CommandBarAction) -> [CommandBarAction] {
    [expression]
  }

  static func buildExpression(_ expression: CommandBarAction?) -> [CommandBarAction] {
    expression.map { [$0] } ?? []
  }

  static func buildExpression(_ expression: [CommandBarAction]) -> [CommandBarAction] {
    expression
  }

  static func buildOptional(_ component: [CommandBarAction]?) -> [CommandBarAction] {
    component ?? []
  }

  static func buildEither(first component: [CommandBarAction]) -> [CommandBarAction] {
    component
  }

  static func buildEither(second component: [CommandBarAction]) -> [CommandBarAction] {
    component
  }

  static func buildArray(_ components: [[CommandBarAction]]) -> [CommandBarAction] {
    components.flatMap { $0 }
  }
}

@MainActor
@Observable
final class CommandBarRegistry {
  private(set) var items: [CommandBarItem] = []

  @ObservationIgnored private var groups: [String: [RegisteredCommandBarAction]] = [:]

  func set(_ groupId: String, actions: [CommandBarAction]) {
    if actions.isEmpty {
      remove(groupId)
      return
    }

    groups[groupId] = registeredActions(groupId: groupId, actions: actions)
    rebuild()
  }

  func remove(_ groupId: String) {
    guard groups.removeValue(forKey: groupId) != nil else { return }
    rebuild()
  }

  @discardableResult
  func perform(_ itemId: String) -> Bool {
    for groupId in groups.keys.sorted() {
      guard let registration = groups[groupId]?.first(where: { $0.item.id == itemId }) else {
        continue
      }
      guard registration.item.isEnabled else { return false }

      registration.action.perform()
      return true
    }

    return false
  }

  private func registeredActions(
    groupId: String,
    actions: [CommandBarAction]
  ) -> [RegisteredCommandBarAction] {
    var counts: [String: Int] = [:]

    return actions.map { action in
      let count = counts[action.id, default: 0]
      counts[action.id] = count + 1
      let localId = count == 0 ? action.id : "\(action.id).\(count)"
      let globalId = "\(groupId)::\(localId)"
      return RegisteredCommandBarAction(
        item: action.item(globalId: globalId),
        action: action
      )
    }
  }

  private func rebuild() {
    let nextItems = groups.keys.sorted().flatMap { groupId in
      groups[groupId]?.map(\.item) ?? []
    }

    if items != nextItems {
      items = nextItems
    }
  }
}

extension EnvironmentValues {
  @Entry var commandBarRegistry: CommandBarRegistry?
}

private struct CommandBarModifier<Value: Equatable>: ViewModifier {
  @Environment(\.commandBarRegistry) private var registry
  @State private var generatedId = UUID().uuidString

  let id: String?
  let value: Value
  let build: @MainActor () -> [CommandBarAction]

  func body(content: Content) -> some View {
    let _ = value
    let groupId = id ?? generatedId
    let actions = build()

    content
      .background {
        CommandBarSyncHost(
          registry: registry,
          groupId: groupId,
          actions: actions
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
  }
}

@MainActor
private struct CommandBarSyncHost: NSViewRepresentable {
  let registry: CommandBarRegistry?
  let groupId: String
  let actions: [CommandBarAction]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(
      registry: registry,
      groupId: groupId,
      actions: actions
    )
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.remove()
  }

  @MainActor
  final class Coordinator {
    private weak var registry: CommandBarRegistry?
    private var groupId: String?

    func update(
      registry: CommandBarRegistry?,
      groupId: String,
      actions: [CommandBarAction]
    ) {
      if self.registry !== registry || self.groupId != groupId {
        remove()
      }

      self.registry = registry
      self.groupId = groupId
      registry?.set(groupId, actions: actions)
    }

    func remove() {
      if let groupId {
        registry?.remove(groupId)
      }
      registry = nil
      self.groupId = nil
    }
  }
}

extension View {
  func commandBar(
    @CommandBarBuilder _ build: @escaping @MainActor () -> [CommandBarAction]
  ) -> some View {
    modifier(CommandBarModifier(id: nil, value: true, build: build))
  }

  func commandBar(
    id: String,
    @CommandBarBuilder _ build: @escaping @MainActor () -> [CommandBarAction]
  ) -> some View {
    modifier(CommandBarModifier(id: id, value: true, build: build))
  }

  func commandBar<Value: Equatable>(
    value: Value,
    @CommandBarBuilder _ build: @escaping @MainActor () -> [CommandBarAction]
  ) -> some View {
    modifier(CommandBarModifier(id: nil, value: value, build: build))
  }

  func commandBar<Value: Equatable>(
    id: String,
    value: Value,
    @CommandBarBuilder _ build: @escaping @MainActor () -> [CommandBarAction]
  ) -> some View {
    modifier(CommandBarModifier(id: id, value: value, build: build))
  }
}
