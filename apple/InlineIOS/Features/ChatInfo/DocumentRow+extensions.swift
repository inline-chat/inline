import InlineKit
import InlineUI
import Logger
import SwiftUI

extension DocumentRow {
  // MARK: - Theme

  var textColor: Color {
    .primary
  }

  var labelColor: Color {
     .secondary
  }

  var progressBarColor: Color {
    Color(ThemeManager.shared.selected.accent)
  }

  var fileCircleSize: CGFloat {
    50
  }

  var fileCircleFill: Color {
    .primary.opacity(0.04)
  }

  var contentVPadding: CGFloat {
    14
  }

  var contentHPadding: CGFloat {
    14
  }

  var contentHMargin: CGFloat {
    16
  }

  var fileWrapperCornerRadius: CGFloat {
    18
  }

  // MARK: - UI Components

  @ViewBuilder
  var fileIconCircleButton: some View {
    Button(action: fileIconButtonTapped) {
      ZStack {
        Circle()
          .fill(fileCircleFill)
          .frame(width: fileCircleSize, height: fileCircleSize)

        // Progress indicator
        if case let .downloading(bytesReceived, totalBytes) = documentState,
           totalBytes > 0
        {
          let progress = max(0, min(CGFloat(Double(bytesReceived) / Double(totalBytes)), 1))
          Circle()
            .trim(from: 0, to: progress)
            .stroke(progressBarColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: fileCircleSize, height: fileCircleSize)
            .rotationEffect(.degrees(-90))
        }

        // File icon
        Image(systemName: fileIconName)
          .foregroundColor(fileIconColor)
          .font(.system(size: 22))
      }
    }
    .buttonStyle(PlainButtonStyle())
  }

  @ViewBuilder
  var fileName: some View {
    Text(document.fileName ?? "Unknown File")
      .font(.body)
      .foregroundColor(textColor)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  @ViewBuilder
  var fileSize: some View {
    Text(fileSizeText)
      .font(.callout)
      .foregroundColor(labelColor)
      .frame(minWidth: fileSizeMinWidth, alignment: .leading)
  }

  @ViewBuilder
  var fileData: some View {
    VStack(alignment: .leading, spacing: 2) {
      fileName
      fileSize
    }
  }

  @ViewBuilder
  var fileBackgroundRect: some View {
    RoundedRectangle(cornerRadius: fileWrapperCornerRadius)
      .fill(fileBackgroundColor)
  }

  var fileBackgroundColor: Color {
    Color(UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .dark {
        UIColor(hex: "#141414") ?? UIColor.systemGray6
      } else {
        UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
      }
    })
  }

  // MARK: - Computed Properties

  var fileTypeIconName: String {
    DocumentIconResolver.symbolName(
      mimeType: document.mimeType,
      fileName: document.fileName,
      style: .filled
    )
  }

  var fileIconName: String {
    switch documentState {
      case .needsDownload:
        "arrow.down"
      case .downloading:
        "xmark"
      case .locallyAvailable:
        fileTypeIconName
    }
  }

  var fileIconColor: Color {
    switch documentState {
      case .needsDownload, .downloading:
        Color(ThemeManager.shared.selected.accent)
      case .locallyAvailable:
        .gray
    }
  }

  var fileSizeText: String {
    switch documentState {
      case .locallyAvailable, .needsDownload:
        return FileHelpers.formatFileSize(UInt64(document.size ?? 0))
      case let .downloading(bytesReceived, totalBytes):
        let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
        let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
        return "\(downloadedStr) / \(totalStr)"
    }
  }

  var fileSizeMinWidth: CGFloat {
    // Calculate approximate width needed for file size text
    let sampleText = FileHelpers.formatFileSize(UInt64(document.size ?? 0))
    return max(80, CGFloat(sampleText.count * 8))
  }
}
