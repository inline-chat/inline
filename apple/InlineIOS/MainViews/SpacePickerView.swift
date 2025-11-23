import InlineKit
import InlineUI
import SwiftUI

struct SpacePickerView: View {
  @EnvironmentObject var homeViewModel: HomeViewModel

  var sortedSpaces: [HomeSpaceItem] {
    homeViewModel.spaces.sorted { s1, s2 in
      s1.space.date > s2.space.date
    }
  }

  var longestLabelText: String {
    let font = labelUIFont
    return (["Home"] + sortedSpaces.map(\.space.name))
      .max(by: { $0.width(using: font) < $1.width(using: font) }) ?? "Home"
  }

  var selectedSpace: Space? {
    homeViewModel.selectedSpace
  }

  private var labelUIFont: UIFont {
    let base = UIFont.preferredFont(forTextStyle: .body)
    return UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
  }

  var body: some View {
    Menu {
      Button {
        homeViewModel.selectSpace(nil)
      } label: {
        Label {
          Text("Home")
        } icon: {
          Image("lineIcon")
            .resizable()
            .frame(width: 16, height: 16)
        }
      }

      ForEach(sortedSpaces) { spaceItem in
        Button {
          homeViewModel.selectSpace(spaceItem.space.id)
        } label: {
          Label {
            Text(spaceItem.space.name)
          } icon: {
            Image(systemName: "building.2.fill")
              .font(.callout)
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Group {
          if selectedSpace != nil {
            Rectangle()
              .fill(.clear)
              .frame(width: 22, height: 22)
              .overlay(
                Image(systemName: "building.2.fill")
                  .font(.callout)
              )
          } else {
            Image("lineIcon")
              .resizable()
              .frame(width: 22, height: 22)
          }
        }
        ZStack(alignment: .leading) {
          Text(longestLabelText)
            .lineLimit(1)
            .opacity(0)
          Text(selectedSpace?.name ?? "Home")
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Image(systemName: "chevron.down")
          .font(.caption2)
          .fontWeight(.semibold)
      }
      .font(.system(size: labelUIFont.pointSize, weight: .semibold))
    }
  }
}

extension String {
  func width(using font: UIFont) -> CGFloat {
    let attributedString = NSAttributedString(string: self, attributes: [.font: font])
    return attributedString.size().width
  }
}
