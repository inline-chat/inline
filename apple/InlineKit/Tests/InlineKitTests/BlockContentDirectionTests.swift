import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Block content direction")
struct BlockContentDirectionTests {
  private func range(_ text: String, of part: String) -> BlockText {
    let found = (text as NSString).range(of: part)
    return .with { $0.offset = Int64(found.location); $0.length = Int64(found.length) }
  }

  private func paragraph(_ text: BlockText) -> Block {
    .with { $0.paragraph = text }
  }

  @Test("The majority of words decides, ties going to the first strong letter")
  func words() {
    #expect(BlockContentDirection.isRTL("123 😀 —") == nil)
    #expect(BlockContentDirection.isRTL("سلام English") == true)
    #expect(BlockContentDirection.isRTL("English سلام") == false)
    #expect(BlockContentDirection.isRTL("Claude Code حداقل 2.1.321 لازم دارد، پس نسخهٔ 2.1.322 کافی است.") == true)
    #expect(BlockContentDirection.isRTL("I talked to محمد about the deploy") == false)
    // ZWNJ keeps "می‌شود" one word, so this is a tie that the Latin letter wins.
    #expect(BlockContentDirection.isRTL("Opus می\u{200C}شود") == false)
  }

  @Test("Every block gets its own direction, list items included, replacing stored flags")
  func resolves() throws {
    let text = "Sources:\nClaude Code حداقل این نسخه لازم دارد\nModels overview\nسلام دنیا"
    var stale = range(text, of: "Sources:")
    stale.isRtl = true
    let content = BlockContent.with {
      $0.blocks = [
        paragraph(stale),
        .with {
          $0.list = .with {
            $0.kind = .unordered
            // The server's first-letter flag for this list.
            $0.isRtl = false
            $0.items = [
              .with { $0.children = [paragraph(range(text, of: "Claude Code حداقل این نسخه لازم دارد"))] },
              .with { $0.children = [paragraph(range(text, of: "Models overview"))] },
            ]
          }
        },
        .with { $0.quote = .with { $0.children = [paragraph(range(text, of: "سلام دنیا"))] } },
      ]
    }

    let resolved = BlockContentDirection.resolved(content, text: text)
    #expect(resolved.blocks[0].paragraph.isRtl == false)
    let list = resolved.blocks[1].list
    #expect(BlockContentDirection.direction(of: list.items[0]) == true)
    #expect(BlockContentDirection.direction(of: list.items[1]) == false)
    // Five Persian words against four Latin ones across the list.
    #expect(list.isRtl == true)
    #expect(resolved.blocks[2].quote.isRtl == true)
  }

  @Test("Code and text without letters carry no direction")
  func neutral() {
    let text = "let x = 1\n123"
    let content = BlockContent.with {
      $0.blocks = [
        .with { $0.code = .with { $0.text = range(text, of: "let x = 1") } },
        paragraph(range(text, of: "123")),
      ]
    }
    let resolved = BlockContentDirection.resolved(content, text: text)
    #expect(!resolved.blocks[0].code.text.hasIsRtl)
    #expect(!resolved.blocks[1].paragraph.hasIsRtl)
  }
}
