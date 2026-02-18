import Testing

@testable import InlineKit

@Suite("Document Icon Resolver")
struct DocumentIconResolverTests {
  @Test("Resolves spreadsheet icon from MIME type")
  func resolvesSpreadsheetFromMimeType() {
    let icon = DocumentIconResolver.symbolName(
      mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      fileName: "report.unknown",
      style: .filled
    )

    #expect(icon == "tablecells.fill")
  }

  @Test("Resolves document icon from extension fallback")
  func resolvesDocumentFromExtension() {
    let icon = DocumentIconResolver.symbolName(
      mimeType: nil,
      fileName: "proposal.DOCX",
      style: .filled
    )

    #expect(icon == "text.document.fill")
  }

  @Test("Resolves generic audio to sound icon")
  func resolvesAudioToWaveform() {
    let icon = DocumentIconResolver.symbolName(
      mimeType: "audio/ogg",
      fileName: "voice-note.ogg",
      style: .filled
    )

    #expect(icon == "waveform")
  }

  @Test("Resolves regular style symbols for macOS")
  func resolvesRegularStyle() {
    let icon = DocumentIconResolver.symbolName(
      mimeType: nil,
      fileName: "budget.xlsx",
      style: .regular
    )

    #expect(icon == "tablecells")
  }

  @Test("Falls back to generic file icon")
  func fallsBackToGenericIcon() {
    let icon = DocumentIconResolver.symbolName(
      mimeType: nil,
      fileName: "blob.unknown",
      style: .filled
    )

    #expect(icon == "document.fill")
  }
}
