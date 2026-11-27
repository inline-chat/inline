import AppKit
import Testing
@testable import InlineContextMenu

@MainActor
@Suite struct MenuModelTests {
  @Test func separatorsCollapseAndTrim() {
    let menu = NSMenu()
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "A", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(.separator())
    let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
    hidden.isHidden = true
    menu.addItem(hidden)
    menu.addItem(NSMenuItem(title: "B", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    let rows = MenuModel.rows(for: menu, modifiers: [])
    #expect(rows.map(\.kind) == [.item, .separator, .item])
  }

  @Test func optionShowsAlternate() {
    let menu = NSMenu()
    let base = NSMenuItem(title: "Copy Text", action: nil, keyEquivalent: "c")
    let alternate = NSMenuItem(title: "Copy + Entities", action: nil, keyEquivalent: "c")
    alternate.keyEquivalentModifierMask = [.command, .option]
    alternate.isAlternate = true
    menu.addItem(base)
    menu.addItem(alternate)
    #expect(MenuModel.rows(for: menu, modifiers: []).map(\.item.title) == ["Copy Text"])
    #expect(MenuModel.rows(for: menu, modifiers: [.option]).map(\.item.title) == ["Copy + Entities"])
  }

  @Test func shortcutText() {
    let item = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "\u{8}")
    #expect(MenuModel.keyEquivalentText(for: item) == "⌘⌫")
    let shifted = NSMenuItem(title: "Quote", action: nil, keyEquivalent: "R")
    #expect(MenuModel.keyEquivalentText(for: shifted) == "⇧⌘R")
  }

  @Test func footnotesAreNotSelectable() {
    let item = NSMenuItem(title: "Edited", action: nil, keyEquivalent: "")
    item.contextMenuStyle = .footnote
    #expect(MenuRow(item: item, kind: .item).isSelectable == false)
  }
}
