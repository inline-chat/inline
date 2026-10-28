import InlineKit
import InlineUI
import SwiftUI

struct DocumentsTabView: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel
  let peerUserId: Int64?
  let peerThreadId: Int64?
  let onShowInChat: (Message) -> Void

  var body: some View {
    VStack(spacing: 16) {
      if !documentsViewModel.documentMessages.isEmpty {
        // Documents content without scroll
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(documentsViewModel.groupedDocumentMessages, id: \.date) { group in
            ChatInfoDateSection(
              dateText: formatDate(group.date),
              headerInsets: EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 0)
            ) {
              // Documents for this date
              ForEach(group.messages, id: \.id) { documentMessage in
                DocumentRow(
                  documentMessage: documentMessage,
                  chatId: peerThreadId,
                  onShowInChat: { onShowInChat(documentMessage.message) }
                )
                .padding(.bottom, 4)
                .onAppear {
                  Task {
                    await documentsViewModel.loadMoreIfNeeded(currentMessageId: documentMessage.message.id)
                  }
                }
              }
            }
          }
        }
      }
      ChatInfoResourceFooter(
        state: documentsViewModel.loadState, isEmpty: documentsViewModel.documentMessages.isEmpty,
        emptyMessage: "No files found in this chat.", loadMore: documentsViewModel.loadMore,
        retry: documentsViewModel.retry
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await documentsViewModel.loadInitial()
    }
    .onDisappear { documentsViewModel.deactivate() }
  }

  /// Format date for display
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
