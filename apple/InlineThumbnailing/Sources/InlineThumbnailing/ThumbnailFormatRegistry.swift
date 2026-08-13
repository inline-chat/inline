import Foundation
import UniformTypeIdentifiers

struct ThumbnailFormatDescriptor: Sendable {
  enum Strategy: Sendable {
    case imageIO
    case customFirst(CustomDocumentKind)
    case quickLookThenCustom(CustomDocumentKind)
    case quickLookOnly
  }

  let extensions: Set<String>
  let typeIdentifiers: Set<String>
  let cohort: ThumbnailCohort
  let minimumMacOSMajor: Int
  let minimumIOSMajor: Int
  let strategy: Strategy

  func isAvailable(policy: ThumbnailPolicy) -> Bool {
    guard policy.enabledCohorts.contains(cohort) else { return false }
    #if os(macOS)
    return policy.systemVersion.major >= minimumMacOSMajor
    #else
    return policy.systemVersion.major >= minimumIOSMajor
    #endif
  }
}

enum CustomDocumentKind: Sendable {
  case plainText
  case delimited(Character)
  case json
  case markdown
}

enum ThumbnailFormatRegistry {
  private static let descriptors: [ThumbnailFormatDescriptor] = [
    descriptor(
      extensions: ["pdf"],
      typeIdentifiers: [UTType.pdf.identifier],
      cohort: .core,
      strategy: .imageIO
    ),
    descriptor(
      extensions: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"],
      typeIdentifiers: [
        "public.jpeg",
        "public.png",
        "com.compuserve.gif",
        "org.webmproject.webp",
        "public.heic",
        "public.heif",
        "public.tiff",
        "com.microsoft.bmp",
      ],
      cohort: .core,
      strategy: .imageIO
    ),
    descriptor(
      extensions: ["json"],
      typeIdentifiers: ["public.json"],
      cohort: .structuredText,
      strategy: .customFirst(.json)
    ),
    descriptor(
      extensions: ["md", "markdown", "mdown", "mkdn"],
      typeIdentifiers: ["net.daringfireball.markdown"],
      cohort: .structuredText,
      strategy: .customFirst(.markdown)
    ),
    descriptor(
      extensions: ["csv"],
      typeIdentifiers: ["public.comma-separated-values-text"],
      cohort: .structuredText,
      strategy: .customFirst(.delimited(","))
    ),
    descriptor(
      extensions: ["tsv"],
      typeIdentifiers: ["public.tab-separated-values-text"],
      cohort: .structuredText,
      strategy: .customFirst(.delimited("\t"))
    ),
    descriptor(
      extensions: ["txt", "text", "log"],
      typeIdentifiers: [UTType.plainText.identifier],
      cohort: .structuredText,
      strategy: .quickLookThenCustom(.plainText)
    ),
    descriptor(
      extensions: ["docx"],
      typeIdentifiers: ["org.openxmlformats.wordprocessingml.document"],
      cohort: .modernDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["xlsx"],
      typeIdentifiers: ["org.openxmlformats.spreadsheetml.sheet"],
      cohort: .modernDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["pptx"],
      typeIdentifiers: ["org.openxmlformats.presentationml.presentation"],
      cohort: .modernDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["rtf"],
      typeIdentifiers: [UTType.rtf.identifier],
      cohort: .modernDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["svg"],
      typeIdentifiers: ["public.svg-image"],
      cohort: .webDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["html", "htm", "xhtml"],
      typeIdentifiers: [UTType.html.identifier, "public.xhtml"],
      cohort: .webDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["pages"],
      typeIdentifiers: ["com.apple.iwork.pages.pages"],
      cohort: .appleDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["numbers"],
      typeIdentifiers: ["com.apple.iwork.numbers.numbers"],
      cohort: .appleDocuments,
      strategy: .quickLookOnly
    ),
    descriptor(
      extensions: ["key"],
      typeIdentifiers: ["com.apple.iwork.keynote.key"],
      cohort: .appleDocuments,
      strategy: .quickLookOnly
    ),
  ]

  static func descriptor(for url: URL, contentType: UTType?, policy: ThumbnailPolicy) -> ThumbnailFormatDescriptor? {
    let fileExtension = url.pathExtension.lowercased()
    let typeIdentifier = contentType?.identifier

    if let exact = descriptors.first(where: {
      $0.extensions.contains(fileExtension) || typeIdentifier.map($0.typeIdentifiers.contains) == true
    }) {
      return exact.isAvailable(policy: policy) ? exact : nil
    }

    return nil
  }

  private static func descriptor(
    extensions: Set<String>,
    typeIdentifiers: Set<String>,
    cohort: ThumbnailCohort,
    strategy: ThumbnailFormatDescriptor.Strategy
  ) -> ThumbnailFormatDescriptor {
    ThumbnailFormatDescriptor(
      extensions: extensions,
      typeIdentifiers: typeIdentifiers,
      cohort: cohort,
      minimumMacOSMajor: 15,
      minimumIOSMajor: 18,
      strategy: strategy
    )
  }
}
