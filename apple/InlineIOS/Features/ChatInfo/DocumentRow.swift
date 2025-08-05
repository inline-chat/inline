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

  let documentInfo: DocumentInfo?

  @State var isBeingRemoved = false
  @State var documentState: DocumentState = .needsDownload
  @State var progressSubscription: AnyCancellable?
  @State var showingQuickLook = false
  @State var showingDocumentPicker = false
  @State var showingAlert = false
  @State var alertMessage = ""
  @State var documentURL: URL?
  @State var rotationAngle: Double = 0

  enum DocumentState: Equatable {
    case locallyAvailable
    case needsDownload
    case downloading(bytesReceived: Int64, totalBytes: Int64)
  }

  var document: Document? {
    documentInfo?.document
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
      if let documentURL {
        QuickLookView(url: documentURL)
      }
    }
    .alert("Cannot Open Document", isPresented: $showingAlert) {
      Button("OK") {}
    } message: {
      Text(alertMessage)
    }
  }
}
