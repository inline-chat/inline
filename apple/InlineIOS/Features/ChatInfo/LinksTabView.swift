import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct LinksTabView: View {
  @ObservedObject var linksViewModel: ChatLinksViewModel

  var body: some View {
    VStack(spacing: 16) {
      if linksViewModel.linkMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No links found in this chat.")

          Text("Older links may not appear, will be fixed in an update.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(linksViewModel.groupedLinkMessages, id: \.date) { group in
            Section {
              ForEach(group.messages) { linkMessage in
                LinkRow(linkMessage: linkMessage)
                  .padding(.bottom, 4)
                  .onAppear {
                    Task {
                      await linksViewModel.loadMoreIfNeeded(currentMessageId: linkMessage.message.messageId)
                    }
                  }
              }
            } header: {
              HStack {
                Text(formatDate(group.date))
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color(.systemBackground).opacity(0.95))
                  )
                  .padding(.leading, 16)
                Spacer()
              }
              .padding(.top, 16)
              .padding(.bottom, 8)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await linksViewModel.loadInitial()
    }
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }
}

private struct LinkRow: View {
  let linkMessage: LinkMessage

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      linkIconCircle
      linkData
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, contentVPadding)
    .padding(.horizontal, contentHPadding)
    .background {
      fileBackgroundRect
    }
    .padding(.horizontal, contentHMargin)
    .contentShape(RoundedRectangle(cornerRadius: fileWrapperCornerRadius))
    .onTapGesture {
      openLink()
    }
  }

  private var linkText: String {
    if let urlString = linkMessage.urlPreview?.url, !urlString.isEmpty {
      return urlString
    }
    if let text = linkMessage.message.text,
       let url = firstLinkURL(from: text)
    {
      return url.absoluteString
    }
    if let text = linkMessage.message.text, !text.isEmpty {
      return text
    }
    return "Link"
  }

  private var linkURL: URL? {
    URL(string: linkText)
  }

  private func openLink() {
    guard let url = linkURL else { return }
    UIApplication.shared.open(url)
  }

  private var linkIconCircle: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: linkIconCornerRadius)
        .fill(fileCircleFill)
        .frame(width: fileCircleSize, height: fileCircleSize)

      Image(systemName: "link")
        .foregroundColor(linkIconColor)
        .font(.system(size: 11))
        .padding(.top, linkIconTopPadding)
    }
  }

  private var linkData: some View {
    Text(linkText)
      .font(.body)
      .foregroundColor(.blue)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var fileCircleSize: CGFloat {
    25
  }

  private var linkIconCornerRadius: CGFloat {
    6
  }

  private var linkIconTopPadding: CGFloat {
    5
  }

  private var fileCircleFill: Color {
    .primary.opacity(0.04)
  }

  private var contentVPadding: CGFloat {
    14
  }

  private var contentHPadding: CGFloat {
    14
  }

  private var contentHMargin: CGFloat {
    16
  }

  private var fileWrapperCornerRadius: CGFloat {
    18
  }

  private var linkIconColor: Color {
    .secondary
  }

  private var fileBackgroundRect: some View {
    RoundedRectangle(cornerRadius: fileWrapperCornerRadius)
      .fill(fileBackgroundColor)
  }

  private var fileBackgroundColor: Color {
    Color(UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .dark {
        UIColor(hex: "#141414") ?? UIColor.systemGray6
      } else {
        UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
      }
    })
  }

  private func firstLinkURL(from text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    return detector.firstMatch(in: text, options: [], range: range)?.url
  }
}
