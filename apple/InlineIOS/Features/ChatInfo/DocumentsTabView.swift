import InlineKit
import InlineUI
import SwiftUI

struct DocumentsTabView: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel
  let peerUserId: Int64?
  let peerThreadId: Int64?

  var body: some View {
    VStack(spacing: 16) {
      if documentsViewModel.documentMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No files found in this chat.")
            .foregroundColor(.primary)
          Text("Older files may not appear, will be fixed in an update.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        // Documents content without scroll
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(documentsViewModel.groupedDocumentMessages, id: \.date) { group in
            Section {
              // Documents for this date
              ForEach(group.messages, id: \.id) { documentMessage in
                DocumentRow(
                  documentMessage: documentMessage,
                  chatId: peerThreadId
                )
                .padding(.bottom, 4)
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
  }

  // Format date for display
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
