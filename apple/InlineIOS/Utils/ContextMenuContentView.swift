import SwiftUI
import UIKit

struct ContextMenuContentView: View {
  let elements: [ContextMenuElement]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(elements.enumerated()), id: \.offset) { tuple in
        let index = tuple.offset
        let element = tuple.element
        switch element {
          case let .item(item):
            menuButton(for: item)
          case .separator:
            if index > 0, index < elements.count - 1 {
              Divider()
            }
        }
      }
    }
    .frame(minWidth: 230)
    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
  }

  private func menuButton(for item: ContextMenuItem) -> some View {
    Button(action: item.action) {
      HStack {
        Text(item.title)
          .font(.callout)
          .foregroundColor(item.isDestructive ? .red : .primary)
        Spacer()
        if let icon = item.icon {
          Image(uiImage: icon)
            .font(.caption)
            .foregroundColor(item.isDestructive ? .red : .primary)
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
    }
    .buttonStyle(.plain)
  }
}
