import InlineKit
import InlineUI
import SwiftUI

/// The Files tab: inset grouped month cards of file rows, newest first.
///
/// Content for a section of the chat info page's scroll view; it has no scroll view
/// of its own. Rows are sliced card segments in one lazy stack, so a month with
/// hundreds of files never builds as one view.
struct DocumentsTabView: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel
  let peerUserId: Int64?
  let peerThreadId: Int64?
  let onShowInChat: (Message) -> Void

  @State private var model = ChatInfoResourceListModel<DocumentMessage, ChatInfoResourceListItem<DocumentMessage>>()

  var body: some View {
    let sections = model.cache.sections(
      for: documentsViewModel.documentMessages,
      date: \.message.date,
      id: \.message.messageId
    ) { document, placement in
      ChatInfoResourceListItem(id: document.id, placement: placement, row: document)
    }

    LazyVStack(spacing: 0) {
      ForEach(sections) { section in
        Section {
          ForEach(section.items) { item in
            DocumentRow(
              documentMessage: item.row,
              chatId: peerThreadId,
              onShowInChat: { onShowInChat(item.row.message) }
            )
            .chatInfoResourceRow(item.placement.position)
            .onAppear { model.itemAppeared(item.placement.index, window: documentsViewModel) }
          }
        } header: {
          ChatInfoResourceSectionHeader(title: section.title)
        }
      }

      ChatInfoResourceFooter(
        state: documentsViewModel.loadState,
        rowCount: documentsViewModel.documentMessages.count,
        empty: .init(systemImage: "doc", message: "No files yet"),
        onReachEnd: { model.pager.requestMore(documentsViewModel) },
        retry: { model.pager.retry(documentsViewModel) }
      )
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .task {
      #if DEBUG
      await ChatInfoResourceHarness.seedIfRequested()
      #endif
      await documentsViewModel.loadInitial()
    }
    .onDisappear { documentsViewModel.deactivate() }
  }
}
