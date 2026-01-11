import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct DocumentRow: View {
  // MARK: - Properties

  let documentMessage: DocumentMessage
  let chatId: Int64?

  @State var isBeingRemoved = false
  @State var documentState: DocumentState = .needsDownload
  @State var progressSubscription: AnyCancellable?
  @State var showingQuickLook = false
  @State var showingAlert = false
  @State var alertMessage = ""
  @State var docInteractionController: UIDocumentInteractionController? = nil

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
  }

  var documentInfo: DocumentInfo { documentMessage.document }
  var document: Document { documentInfo.document }
  
  // MARK: - Computed Properties
  
  /// The file URL for the document if it exists locally
  var documentURL: URL? {
    guard let localPath = document.localPath else {
      return nil
    }
    
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let fileURL = cacheDirectory.appendingPathComponent(localPath)
    
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

  init(documentMessage: DocumentMessage, chatId: Int64? = nil) {
    self.documentMessage = documentMessage
    self.chatId = chatId
  }

  // MARK: - Body

  var body: some View {
    HStack(spacing: 9) {
      fileIconCircleButton
      fileData
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, contentVPadding)
    .padding(.horizontal, contentHPadding)
    .background {
      fileBackgroundRect
    }
    .padding(.horizontal, contentHMargin)
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
    }
    .onTapGesture {
      viewTapped()
    }
    .onAppear {
      setupInitialState()
    }
    .onDisappear {
      cleanup()
    }
    .sheet(isPresented: $showingQuickLook) {
      quickLookPreview
    }
    .alert("Cannot Open Document", isPresented: $showingAlert) {
      Button("OK") {}
    } message: {
      Text(alertMessage)
    }
  }
}
