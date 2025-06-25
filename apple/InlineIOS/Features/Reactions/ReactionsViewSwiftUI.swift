import InlineKit
import SwiftUI

// Custom flow layout implementation
struct FlowLayout: Layout {
  var spacing: CGFloat
  var lineSpacing: CGFloat
    
  init(spacing: CGFloat = 8, lineSpacing: CGFloat = 10) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing
  }
    
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
    var width: CGFloat = 0
    var height: CGFloat = 0
    var currentRowWidth: CGFloat = 0
    var currentRowHeight: CGFloat = 0
        
    let availableWidth = proposal.width ?? .infinity
        
    for size in sizes {
      if currentRowWidth + size.width <= availableWidth {
        currentRowWidth += size.width + spacing
        currentRowHeight = max(currentRowHeight, size.height)
      } else {
        width = max(width, currentRowWidth - spacing)
        height += currentRowHeight + lineSpacing
        currentRowWidth = size.width + spacing
        currentRowHeight = size.height
      }
    }
        
    width = max(width, currentRowWidth - spacing)
    height += currentRowHeight
        
    return CGSize(width: width, height: height)
  }
    
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
    var currentX = bounds.minX
    var currentY = bounds.minY
    var rowHeight: CGFloat = 0
        
    for (index, subview) in subviews.enumerated() {
      let size = sizes[index]
            
      if currentX + size.width > bounds.maxX {
        currentX = bounds.minX
        currentY += rowHeight + lineSpacing
        rowHeight = 0
      }
            
      subview.place(
        at: CGPoint(x: currentX, y: currentY),
        proposal: ProposedViewSize(size)
      )
            
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

struct ReactionsView: View {
  var reactions: [Reaction]

  init(reactions: [Reaction]) {
    self.reactions = reactions
  }

  var reactionsDict: [String: Int] {
    var dict = [String: Int]()
    for reaction in reactions {
      dict[reaction.emoji, default: 0] += 1
    }
    return dict
  }

  var body: some View {
    FlowLayout(spacing: 6, lineSpacing: 6) {
      ForEach(reactionsDict.sorted(by: { $0.value > $1.value }), id: \.key) { reaction, count in
        HStack(spacing: 4) {
          Text(reaction)
            .font(.system(size: 17))

          Text("\(count)")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
        }
        .frame(width: 45, height: 26)
        .background(Color(.systemGray6))
        .cornerRadius(14)
      }
    }
  }
}

#Preview {
  VStack {
    Text("This a message")
      .foregroundStyle(.white)
    ReactionsView(reactions: [
      Reaction(
        id: 1,
        messageId: 1,
        userId: 1,
        emoji: "👍",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "👍",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 1,
        emoji: "💕",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "🥹",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "😍",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "😭",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "🐹",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "🧁",
        date: Date(),
        chatId: 1
      ),
      Reaction(
        id: 1,
        messageId: 1,
        userId: 2,
        emoji: "❌",
        date: Date(),
        chatId: 1
      )
    ])
  }
  .padding(12)
  .background(ColorManager.shared.swiftUIColor)
  .cornerRadius(18)
}
