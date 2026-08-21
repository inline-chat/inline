import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Block content reconciler")
struct BlockContentReconcilerTests {
  @Test("reuses only compatible nodes at the same structural path")
  func compatiblePathReuse() {
    let previous = content([
      paragraph(),
      image(photoID: 10),
    ])
    let current = content([
      heading(),
      image(photoID: 10),
      paragraph(),
    ])

    let result = BlockContentReconciler.reconcile(previous: previous, current: current)

    #expect(result.reusablePaths == Set([BlockContentPath([.block(1)])]))
    #expect(result.insertedPaths.contains(BlockContentPath([.block(0)])))
    #expect(result.insertedPaths.contains(BlockContentPath([.block(2)])))
    #expect(result.removedPaths.contains(BlockContentPath([.block(0)])))
    #expect(result.photoMoves.isEmpty)
  }

  @Test("reports a unique ready photo moving without treating it as a block key")
  func reportsPhotoMove() {
    let previous = content([image(photoID: 77), paragraph()])
    let current = content([paragraph(), image(photoID: 77)])

    let result = BlockContentReconciler.reconcile(previous: previous, current: current)

    #expect(result.photoMoves == [
      .init(
        photoID: 77,
        from: BlockContentPath([.block(0)]),
        to: BlockContentPath([.block(1)])
      ),
    ])
  }

  @Test("reuses list markers and nested children by index path")
  func listItemReuse() {
    let previous = content([list([paragraph()])])
    let current = content([list([paragraph(), paragraph()])])

    let result = BlockContentReconciler.reconcile(previous: previous, current: current)

    #expect(result.reusablePaths.contains(BlockContentPath([.block(0)])))
    #expect(result.reusablePaths.contains(BlockContentPath([.block(0), .listItem(0)])))
    #expect(result.reusablePaths.contains(BlockContentPath([.block(0), .listItem(0), .block(0)])))
    #expect(result.insertedPaths.contains(BlockContentPath([.block(0), .listItem(0), .block(1)])))
  }

  private func content(_ blocks: [InlineProtocol.Block]) -> InlineProtocol.BlockContent {
    .with { $0.blocks = blocks }
  }

  private func paragraph() -> InlineProtocol.Block {
    .with { $0.paragraph = .with { $0.length = 1 } }
  }

  private func heading() -> InlineProtocol.Block {
    .with {
      $0.heading = .with {
        $0.text = .with { $0.length = 1 }
        $0.level = 1
      }
    }
  }

  private func image(photoID: Int64) -> InlineProtocol.Block {
    .with { $0.image = .with { $0.ready = .with { $0.id = photoID } } }
  }

  private func list(_ children: [InlineProtocol.Block]) -> InlineProtocol.Block {
    .with {
      $0.list = .with {
        $0.kind = .unordered
        $0.items = [.with { $0.children = children }]
      }
    }
  }
}
