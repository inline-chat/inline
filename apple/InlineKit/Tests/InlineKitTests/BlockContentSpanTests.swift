import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Block content span")
struct BlockContentSpanTests {
  private func range(_ text: String, of part: String) -> BlockText {
    let found = (text as NSString).range(of: part)
    return .with { $0.offset = Int64(found.location); $0.length = Int64(found.length) }
  }

  private func string(_ range: Range<Int>?, in text: String) -> String? {
    range.map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
  }

  /// A block of a kind newer than this build: an unknown field, so `kind` is nil.
  private func unknownBlock() throws -> Block {
    // Field 99, length-delimited, empty.
    try Block(serializedBytes: [0x9A, 0x06, 0x00])
  }

  @Test("A block's span covers all of its text, children included")
  func spans() {
    let text = "Plan\nRead the code\nrunning\nWrite the fix"
    let steps = Block.with {
      $0.steps = .with {
        $0.steps = [
          .with { $0.text = range(text, of: "Read the code"); $0.detail = range(text, of: "running") },
          .with { $0.text = range(text, of: "Write the fix") },
        ]
      }
    }
    #expect(string(BlockContentSpan.span(of: steps), in: text) == "Read the code\nrunning\nWrite the fix")

    let callout = Block.with {
      $0.callout = .with {
        $0.title = range(text, of: "Plan")
        $0.children = [.with { $0.paragraph = range(text, of: "Read the code") }]
      }
    }
    #expect(string(BlockContentSpan.span(of: callout), in: text) == "Plan\nRead the code")
    #expect(BlockContentSpan.span(of: .with { $0.separator = .init() }) == nil)
  }

  @Test("A known kind falls back to its own span")
  func knownFallback() {
    let text = "Intro\n\n  Approve the plan?  \n\nOutro"
    let blocks: [Block] = [
      .with { $0.paragraph = range(text, of: "Intro") },
      .with { $0.form = .with { $0.title = range(text, of: "  Approve the plan?  ") } },
      .with { $0.paragraph = range(text, of: "Outro") },
    ]
    let fallback = BlockContentSpan.fallbackRange(at: 1, in: blocks, text: text as NSString)
    #expect(string(fallback, in: text) == "Approve the plan?")
  }

  @Test("An unknown kind shows the text between its neighbours, once per run")
  func unknownFallback() throws {
    let text = "Intro\nP1 Unknown blocks drop text\nsrc/a.swift:12\nOutro"
    let blocks: [Block] = try [
      .with { $0.paragraph = range(text, of: "Intro") },
      unknownBlock(),
      unknownBlock(),
      .with { $0.paragraph = range(text, of: "Outro") },
    ]
    #expect(blocks[1].kind == nil)
    let gap = BlockContentSpan.fallbackRange(at: 1, in: blocks, text: text as NSString)
    #expect(string(gap, in: text) == "P1 Unknown blocks drop text\nsrc/a.swift:12")
    #expect(BlockContentSpan.fallbackRange(at: 2, in: blocks, text: text as NSString) == nil)
  }

  @Test("An unknown kind at an edge uses the bounds, and shows nothing without them")
  func edges() throws {
    let text = "Review notes\nOutro"
    let blocks: [Block] = try [unknownBlock(), .with { $0.paragraph = range(text, of: "Outro") }]
    let nsText = text as NSString
    #expect(BlockContentSpan.fallbackRange(at: 0, in: blocks, text: nsText) == nil)
    let bounded = BlockContentSpan.fallbackRange(at: 0, in: blocks, text: nsText, bounds: 0 ..< nsText.length)
    #expect(string(bounded, in: text) == "Review notes")
  }

  @Test("An unknown kind first or last inside a container shows its text, not the title's")
  func nestedEdges() throws {
    let text = "Plan title\nnew kind before\nStep one\nnew kind after\nOutro"
    let children: [Block] = try [unknownBlock(), .with { $0.paragraph = range(text, of: "Step one") }, unknownBlock()]
    let plan = Block.with {
      $0.planProposal = .with {
        $0.title = range(text, of: "Plan title")
        $0.children = children
      }
    }
    let blocks: [Block] = [plan, .with { $0.paragraph = range(text, of: "Outro") }]
    let nsText = text as NSString
    let bounds = BlockContentSpan.childBounds(at: 0, in: blocks, bounds: 0 ..< nsText.length)
    #expect(string(BlockContentSpan.fallbackRange(at: 0, in: children, text: nsText, bounds: bounds), in: text) == "new kind before")
    #expect(string(BlockContentSpan.fallbackRange(at: 2, in: children, text: nsText, bounds: bounds), in: text) == "new kind after")
    #expect(BlockContentSpan.childBounds(at: 1, in: blocks, bounds: bounds) == nil)
  }

  @Test("An unknown kind first or last inside a list item shows its text, between the items")
  func listItemEdges() throws {
    let text = "Intro\nfirst new\nStep one\nmiddle new\nStep two\nlast new\nOutro"
    let first: [Block] = try [unknownBlock(), .with { $0.paragraph = range(text, of: "Step one") }]
    let second: [Block] = try [
      unknownBlock(),
      .with { $0.paragraph = range(text, of: "Step two") },
      unknownBlock(),
    ]
    let list = BlockList.with {
      $0.items = [.with { $0.children = first }, .with { $0.children = second }]
    }
    let blocks: [Block] = [
      .with { $0.paragraph = range(text, of: "Intro") },
      .with { $0.list = list },
      .with { $0.paragraph = range(text, of: "Outro") },
    ]
    let nsText = text as NSString
    let listBounds = BlockContentSpan.childBounds(at: 1, in: blocks, bounds: 0 ..< nsText.length)
    #expect(string(listBounds, in: text) == "\nfirst new\nStep one\nmiddle new\nStep two\nlast new\n")

    let firstBounds = BlockContentSpan.itemBounds(at: 0, in: list, bounds: listBounds)
    #expect(string(BlockContentSpan.fallbackRange(at: 0, in: first, text: nsText, bounds: firstBounds), in: text) == "first new")

    // The second item starts after the first item's text.
    let secondBounds = BlockContentSpan.itemBounds(at: 1, in: list, bounds: listBounds)
    #expect(string(BlockContentSpan.fallbackRange(at: 0, in: second, text: nsText, bounds: secondBounds), in: text) == "middle new")
    #expect(string(BlockContentSpan.fallbackRange(at: 2, in: second, text: nsText, bounds: secondBounds), in: text) == "last new")

    // Without the list's bounds, the outer edges have nothing to stand in for them.
    #expect(BlockContentSpan.itemBounds(at: 0, in: list, bounds: nil) == nil)
    #expect(BlockContentSpan.itemBounds(at: 2, in: list, bounds: listBounds) == nil)
  }

  @Test("A plan proposal's Show full plan state is kept, and follows its title across edits")
  func planOpenState() {
    let text = "Ship the fallback\nStep one"
    func content(leading: Bool) -> BlockContent {
      let plan = Block.with {
        $0.planProposal = .with {
          $0.title = range(text, of: "Ship the fallback")
          $0.children = [.with { $0.paragraph = range(text, of: "Step one") }]
        }
      }
      // An edit that adds a block before the plan moves it to index 1.
      return .with { $0.blocks = leading ? [.with { $0.separator = .init() }, plan] : [plan] }
    }
    let first = BlockContentPath([.block(0)])
    var state = BlockContentDisclosureState()
    state.set(true, path: first, content: BlockContentPayload(content(leading: false)), source: text)
    #expect(state.overrides(content: BlockContentPayload(content(leading: false)), source: text) == [first: true])
    let moved = BlockContentPath([.block(1)])
    #expect(state.overrides(content: BlockContentPayload(content(leading: true)), source: text + " ") == [moved: true])
  }
}
