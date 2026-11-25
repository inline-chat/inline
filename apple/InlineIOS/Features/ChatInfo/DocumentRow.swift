import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A file in the Files tab: a 40 pt type tile (or the file's thumbnail), the name, and
/// "size · date". Tapping downloads, cancels or opens the file, as the tile shows.
///
/// The row draws only its content; `chatInfoResourceRow(_:)` adds the card around it.
struct DocumentRow: View {
  // MARK: - Properties

  let documentMessage: DocumentMessage
  let chatId: Int64?
  let onShowInChat: (() -> Void)?

  @State var isBeingRemoved = false
  @State var documentState: DocumentState = .needsDownload
  @State var progressSubscription: AnyCancellable?
  @State var showingAlert = false
  @State var alertMessage = ""
  @State var docInteractionController: UIDocumentInteractionController? = nil
  /// Set from the tap until QuickLook shows the file: the tile spins and taps wait.
  @State var openingID: UUID?

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
  }

  var documentInfo: DocumentInfo {
    documentMessage.document
  }

  var document: InlineKit.Document {
    documentInfo.document
  }

  // MARK: - Computed Properties

  /// The file URL for the document if it exists locally. Checks the disk, so call it
  /// from actions and state changes, not from `body`.
  var documentURL: URL? {
    guard let localPath = document.localPath else {
      return nil
    }

    let fileURL = ChatInfoResourceFiles.documents.appendingPathComponent(localPath)

    // Only return the URL if the file actually exists
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }

    return fileURL
  }

  /// Whether the document is ready for preview (locally available with valid URL)
  var canPreview: Bool {
    documentState == .locallyAvailable && documentURL != nil
  }

  init(documentMessage: DocumentMessage, chatId: Int64? = nil, onShowInChat: (() -> Void)? = nil) {
    self.documentMessage = documentMessage
    self.chatId = chatId
    self.onShowInChat = onShowInChat
  }

  // MARK: - Body

  var body: some View {
    Button(action: viewTapped) {
      HStack(spacing: ChatInfoResourceMetrics.tileSpacing) {
        fileTile
        fileData
      }
      .padding(.horizontal, ChatInfoResourceMetrics.rowHorizontalPadding)
      .padding(.vertical, ChatInfoResourceMetrics.rowVerticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(ChatInfoResourceRowButtonStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityHint(accessibilityActionHint)
    .accessibilityAddTraits(.isButton)
    .contextMenu {
      switch documentState {
        case .needsDownload:
          Button {
            downloadFile()
          } label: {
            Label("Download", systemImage: "arrow.down.circle")
          }
        case .downloading:
          Button {
            cancelDownload()
          } label: {
            Label("Cancel Download", systemImage: "xmark.circle")
          }
        case .locallyAvailable:
          Button {
            shareDocument()
          } label: {
            Label("Share", systemImage: "square.and.arrow.up")
          }
      }
      if let onShowInChat {
        Button { onShowInChat() } label: {
          Label("Show in Chat", systemImage: "text.bubble")
        }
      }
    }
    .onAppear {
      setupInitialState()
    }
    .onDisappear {
      cleanup()
      openingID = nil
    }
    .alert("Cannot Open Document", isPresented: $showingAlert) {
      Button("OK") {}
    } message: {
      Text(alertMessage)
    }
  }
}
