#if DEBUG || DEBUG_BUILD
import Foundation
import InlineKit
import InlineProtocol
import SwiftUI

struct DeveloperMessageCatalogView: View {
  let configuration: DeveloperMessagePlaygroundConfiguration
  let interactionRevisions: [Int64: UInt64]
  let localRichMediaReady: Bool

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 28) {
        DeveloperMessagePlaygroundHeader(
          title: "Message content catalog",
          detail: "A quick scan of representative single-content and mixed-content FullMessage compositions."
        )

        ForEach(DeveloperMessageCatalogSection.allCases) { section in
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(section.title)
                .font(.title3.weight(.semibold))
              Text(section.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(section.items) { item in
              DeveloperMessageCatalogCard(
                item: item,
                renderer: configuration.renderer,
                width: configuration.canvasWidth.points,
                interactionRevisions: interactionRevisions,
                localRichMediaReady: localRichMediaReady
              )
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(24)
    }
  }
}

private struct DeveloperMessageCatalogCard: View {
  let item: DeveloperMessageCatalogItem
  let renderer: DeveloperMessagePlaygroundRenderer
  let width: CGFloat
  let interactionRevisions: [Int64: UInt64]
  let localRichMediaReady: Bool

  var body: some View {
    let fixture = DeveloperMessageCatalogFactory.make(
      item.kind,
      localRichMediaReady: localRichMediaReady
    )
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.headline)
        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(renderer.styles, id: \.self) { style in
        ForEach(item.codePresentations, id: \.self) { codePresentation in
          VStack(alignment: .leading, spacing: 5) {
            if renderer == .compare || item.codePresentations.count > 1 {
              Text(item.codePresentations.count > 1
                ? "\(style.title) · \(codePresentation.title)"
                : style.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Group {
              if item.kind == .richStreaming {
                DeveloperRichStreamingPreview(
                  width: width,
                  style: style,
                  codePresentation: codePresentation,
                  interactionRevisions: interactionRevisions
                )
              } else {
                DeveloperProductionMessageRow(
                  fixture: fixture,
                  width: width,
                  style: style,
                  codePresentation: codePresentation,
                  interactionRevision: interactionRevisions[fixture.message.message.stableId] ?? 0
                )
              }
            }
            .frame(width: width)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
              RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
          }
        }
      }
    }
  }
}

private struct DeveloperRichStreamingPreview: View {
  let width: CGFloat
  let style: MessageRenderStyle
  let codePresentation: RichBlockCodePresentation
  let interactionRevisions: [Int64: UInt64]

  @State private var revision = 0
  @State private var isPlaying = true

  var body: some View {
    let fixture = DeveloperMessageCatalogFactory.makeStreaming(revision: revision)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          if revision == DeveloperMessageCatalogFactory.streamingRevisionCount - 1 {
            revision = 0
            isPlaying = true
          } else {
            isPlaying.toggle()
          }
        } label: {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause stream" : "Resume stream")

        Button {
          revision = 0
          isPlaying = true
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .help("Restart stream")

        Text("Revision \(revision + 1) of \(DeveloperMessageCatalogFactory.streamingRevisionCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      DeveloperProductionMessageRow(
        fixture: fixture,
        width: width,
        style: style,
        codePresentation: codePresentation,
        interactionRevision: interactionRevisions[fixture.message.message.stableId] ?? 0,
        animateUpdates: true
      )
    }
    .task(id: isPlaying) {
      guard isPlaying else { return }
      while !Task.isCancelled, revision < DeveloperMessageCatalogFactory.streamingRevisionCount - 1 {
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled, isPlaying else { return }
        revision += 1
      }
      if revision == DeveloperMessageCatalogFactory.streamingRevisionCount - 1 {
        isPlaying = false
      }
    }
  }
}

private enum DeveloperMessageCatalogSection: String, CaseIterable, Identifiable {
  case text
  case richContent
  case structure
  case links
  case media
  case mixed

  var id: Self { self }

  var title: String {
    switch self {
    case .text: "Text and direction"
    case .richContent: "Rich content blocks"
    case .structure: "Message state and structure"
    case .links: "URL previews"
    case .media: "Files and media"
    case .mixed: "Mixed compositions"
    }
  }

  var detail: String {
    switch self {
    case .text: "Length, entities, emoji, ownership, and RTL presentation."
    case .richContent: "Headings, inline entities, code, lists, disclosures, image states, albums, and agent-shaped combinations."
    case .structure: "Grouping, replies, forwards, reactions, and delivery states."
    case .links: "Compact, large-media, and multiple attachment layouts."
    case .media: "Photo, video, document, archive, and voice presentation."
    case .mixed: "Several production-supported pieces composed in one message."
    }
  }

  var items: [DeveloperMessageCatalogItem] {
    switch self {
    case .text:
      [
        .init(.shortIncoming, "Short incoming", "Compact text and timestamp"),
        .init(.longOutgoing, "Long outgoing", "Wrapping, maximum width, and outgoing styling"),
        .init(.emoji, "Emoji only", "Large emoji treatment without a normal text bubble"),
        .init(.linkedText, "Text with URL entity", "Production inline-link styling"),
        .init(.rtl, "Right-to-left text", "Persian content with RTL input props"),
      ]
    case .richContent:
      [
        .init(.richMath, "Native display math", "Fractions, matrices, horizontal overflow, source fallback and Copy LaTeX"),
        .init(
          .richCompactText,
          "Compact paragraph + reply",
          "Short rich text uses its rendered width while the reply remains the bubble minimum"
        ),
        .init(
          .richInlineEntities,
          "Paragraph + inline entities",
          "Bold, italic, inline code, raw and labeled links, mention, email, and phone entities"
        ),
        .init(
          .richHierarchy,
          "Headings + separator + footer",
          "A compact document hierarchy with agent attribution"
        ),
        .init(
          .richCode,
          "Paragraph + fenced code",
          "The same multiline Swift fixture in plain and syntax-highlighted presentations",
          codePresentations: [.plain, .syntaxHighlighted]
        ),
        .init(
          .richCodeLanguages,
          "Common code languages",
          "Swift, TypeScript, Python, Shell, HTML, CSS, JSON, YAML, Go, and Rust through native Tree-sitter grammars"
        ),
        .init(
          .richPlainCode,
          "Language-less code",
          "Copy stays overlaid without reserving empty header chrome"
        ),
        .init(
          .richStreaming,
          "Streaming rich message",
          "Four same-message revisions exercise node reuse, disclosure state, animated reflow, and finalization"
        ),
        .init(
          .richNestedLists,
          "Nested unordered + ordered lists",
          "Multiple paragraph children and a numbered nested list starting at three"
        ),
        .init(
          .richChecklist,
          "Task checklist",
          "Unchecked and completed task markers with ordinary list fallback semantics"
        ),
        .init(
          .richDisclosures,
          "Multiple nested disclosures",
          "Open, closed, nested, paragraph, and code disclosure content"
        ),
        .init(
          .richProgressDisclosure,
          "Progress disclosure",
          "Initially open agent progress with shimmer, list, and code"
        ),
        .init(
          .richPendingImage,
          "Pending rich image",
          "A stable landscape placeholder with known dimensions"
        ),
        .init(
          .richUnknownImage,
          "Unknown-size rich image",
          "A compact 4:3 fallback that does not claim the full viewport"
        ),
        .init(
          .richReadyImage,
          "Ready rich image",
          "A local deterministic photo transitions from pending to ready through the production image block"
        ),
        .init(
          .richUnavailableImage,
          "Unavailable rich image",
          "A failed portrait image that keeps its reserved tile"
        ),
        .init(
          .richAlbum,
          "Six-image rich album",
          "Mixed aspect ratios and pending/unavailable states in the custom horizontal row"
        ),
        .init(
          .richAgentAnswer,
          "Complete agent answer",
          "Heading, styled paragraph, progress disclosure, nested work, code, and footer without an implicit separator"
        ),
        .init(
          .richRTLBlocks,
          "Per-block RTL",
          "RTL heading, paragraph, list, and disclosure beside LTR content"
        ),
        .init(
          .richQuote,
          "Block quote",
          "A nested quote with inline emphasis and multiple paragraphs"
        ),
        .init(
          .richTable,
          "Basic table",
          "Header styling, inline entities, column alignment, wrapping, and horizontal panning"
        ),
      ]
    case .structure:
      [
        .init(.groupStart, "Grouped — start", "First message in a sender group"),
        .init(.groupMiddle, "Grouped — middle", "No leading or trailing group edge"),
        .init(.groupEnd, "Grouped — end", "Last message in a sender group"),
        .init(.reply, "Reply", "Embedded replied-to message plus new text"),
        .init(.forwarded, "Forwarded", "Resolved forward sender header"),
        .init(.reactions, "Reactions", "Multiple people and multiple emoji groups"),
        .init(.sending, "Sending", "Outgoing transient delivery state"),
        .init(.failed, "Failed", "Outgoing failed delivery state"),
      ]
    case .links:
      [
        .init(.compactUrlPreview, "Compact URL preview", "Metadata card without large media"),
        .init(.largeUrlPreview, "Large URL preview", "Metadata card with a local image preview"),
        .init(.multipleUrlPreviews, "Multiple URL previews", "Two real attachment views stacked in one message"),
      ]
    case .media:
      [
        .init(.photo, "Photo", "Local deterministic image without a caption"),
        .init(.photoCaption, "Photo with caption", "Native photo slot plus text"),
        .init(.video, "Video", "Video dimensions, thumbnail, duration, and play treatment"),
        .init(.pdf, "PDF document", "Document name, MIME type, and file size"),
        .init(.archive, "Archive file", "Generic file presentation through the document slot"),
        .init(.voice, "Voice message", "Waveform, duration, and voice controls"),
      ]
    case .mixed:
      [
        .init(
          .replyPhotoUrlReactions,
          "Reply + text + photo + URL preview + reactions",
          "The dense mixed composition requested for rapid visual inspection"
        ),
        .init(
          .forwardedDocument,
          "Forwarded + text + document + reactions",
          "Forward context composed with a file and caption"
        ),
        .init(
          .outgoingPhotoLink,
          "Outgoing + link + photo + delivery state",
          "Media caption with a URL entity and outgoing status"
        ),
      ]
    }
  }
}

private struct DeveloperMessageCatalogItem: Identifiable {
  let kind: DeveloperMessageCatalogKind
  let title: String
  let detail: String
  let codePresentations: [RichBlockCodePresentation]

  var id: DeveloperMessageCatalogKind { kind }

  init(
    _ kind: DeveloperMessageCatalogKind,
    _ title: String,
    _ detail: String,
    codePresentations: [RichBlockCodePresentation] = [.syntaxHighlighted]
  ) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.codePresentations = codePresentations
  }
}

private enum DeveloperMessageCatalogKind: String, Identifiable {
  case shortIncoming
  case longOutgoing
  case emoji
  case linkedText
  case rtl
  case richCompactText
  case richInlineEntities
  case richHierarchy
  case richCode
  case richCodeLanguages
  case richPlainCode
  case richStreaming
  case richNestedLists
  case richChecklist
  case richDisclosures
  case richProgressDisclosure
  case richPendingImage
  case richUnknownImage
  case richReadyImage
  case richUnavailableImage
  case richAlbum
  case richAgentAnswer
  case richRTLBlocks
  case richQuote
  case richTable
  case richMath
  case groupStart
  case groupMiddle
  case groupEnd
  case reply
  case forwarded
  case reactions
  case sending
  case failed
  case compactUrlPreview
  case largeUrlPreview
  case multipleUrlPreviews
  case photo
  case photoCaption
  case video
  case pdf
  case archive
  case voice
  case replyPhotoUrlReactions
  case forwardedDocument
  case outgoingPhotoLink

  var id: Self { self }
}

private enum DeveloperMessageCatalogFactory {
  private static let fixtureDate = Date(timeIntervalSince1970: 1_755_000_000)
  private static let chatID: Int64 = 9_001
  static let streamingRevisionCount = 4

  static func make(
    _ kind: DeveloperMessageCatalogKind,
    localRichMediaReady: Bool = false
  ) -> DeveloperMessageFixture {
    let id = Int64(30_000 + catalogIndex(kind) * 100)

    switch kind {
    case .shortIncoming:
      return fixture(id: id, text: "This is the real message renderer.")
    case .longOutgoing:
      return fixture(
        id: id,
        text: "A longer outgoing message makes wrapping, maximum width, line height, timestamp placement, and the relationship between text and the bubble edge easy to inspect at a glance.",
        outgoing: true
      )
    case .emoji:
      return fixture(id: id, text: "🎉✨")
    case .linkedText:
      let text = "Open https://inline.chat to inspect the production link treatment."
      return fixture(id: id, text: text, entities: urlEntities(in: text))
    case .rtl:
      return fixture(
        id: id,
        text: "این یک پیام نمونه برای بررسی چیدمان راست به چپ است.",
        isRtl: true
      )
    case .richMath:
      return richFixture(id: id, content: richMath())
    case .richCompactText:
      return richFixture(id: id, content: richCompactText(), reply: true)
    case .richInlineEntities:
      return richFixture(id: id, content: richInlineEntities())
    case .richHierarchy:
      return richFixture(id: id, content: richHierarchy())
    case .richCode:
      return richFixture(id: id, content: richCode())
    case .richCodeLanguages:
      return richFixture(id: id, content: richCodeLanguages())
    case .richPlainCode:
      return richFixture(id: id, content: richPlainCode())
    case .richStreaming:
      return makeStreaming(revision: streamingRevisionCount - 1)
    case .richNestedLists:
      return richFixture(id: id, content: richNestedLists())
    case .richChecklist:
      return richFixture(id: id, content: richChecklist())
    case .richDisclosures:
      return richFixture(id: id, content: richDisclosures())
    case .richProgressDisclosure:
      return richFixture(id: id, content: richProgressDisclosure())
    case .richPendingImage:
      return richFixture(id: id, content: richPendingImage())
    case .richUnknownImage:
      return richFixture(id: id, content: richUnknownImage())
    case .richReadyImage:
      return richFixture(id: id, content: richReadyImage(isReady: localRichMediaReady))
    case .richUnavailableImage:
      return richFixture(id: id, content: richUnavailableImage())
    case .richAlbum:
      return richFixture(id: id, content: richAlbum(hasReadyPhoto: localRichMediaReady))
    case .richAgentAnswer:
      return richFixture(id: id, content: richAgentAnswer(), outgoing: true, reactions: true)
    case .richRTLBlocks:
      return richFixture(id: id, content: richRTLBlocks())
    case .richQuote:
      return richFixture(id: id, content: richQuote())
    case .richTable:
      return richFixture(id: id, content: richTable())
    case .groupStart:
      return fixture(id: id, text: "First message in this group.", groupPosition: .start)
    case .groupMiddle:
      return fixture(id: id, text: "A middle message keeps the group connected.", groupPosition: .middle)
    case .groupEnd:
      return fixture(id: id, text: "The final message closes the group.", groupPosition: .end)
    case .reply:
      return fixture(id: id, text: "Looks good — I’ll take the final pass.", reply: true)
    case .forwarded:
      return fixture(id: id, text: "Sharing this here so the whole team has the same context.", forwarded: true)
    case .reactions:
      return fixture(id: id, text: "Should we ship this version today?", reactions: true)
    case .sending:
      return fixture(id: id, text: "Uploading the latest build…", outgoing: true, status: .sending)
    case .failed:
      return fixture(id: id, text: "The upload did not finish.", outgoing: true, status: .failed)
    case .compactUrlPreview:
      return fixture(
        id: id,
        text: "The product notes are here:",
        attachments: [urlPreview(messageID: id, attachmentIndex: 1, large: false)]
      )
    case .largeUrlPreview:
      return fixture(
        id: id,
        text: "A visual preview from the launch page:",
        attachments: [urlPreview(messageID: id, attachmentIndex: 1, large: true)]
      )
    case .multipleUrlPreviews:
      return fixture(
        id: id,
        text: "Two references for the review:",
        attachments: [
          urlPreview(messageID: id, attachmentIndex: 1, large: false),
          urlPreview(messageID: id, attachmentIndex: 2, large: true),
        ]
      )
    case .photo:
      return fixture(id: id, text: nil, photo: photoInfo(id: id + 1))
    case .photoCaption:
      return fixture(
        id: id,
        text: "The updated app artwork is ready.",
        photo: photoInfo(id: id + 1)
      )
    case .video:
      return fixture(
        id: id,
        text: "A short product walkthrough.",
        video: videoInfo(id: id + 1)
      )
    case .pdf:
      return fixture(
        id: id,
        text: nil,
        document: documentInfo(id: id + 1, fileName: "Launch checklist.pdf", mimeType: "application/pdf", size: 824_000)
      )
    case .archive:
      return fixture(
        id: id,
        text: "Source files for the handoff.",
        document: documentInfo(id: id + 1, fileName: "inline-assets.zip", mimeType: "application/zip", size: 4_800_000)
      )
    case .voice:
      return fixture(id: id, text: nil, voice: true)
    case .replyPhotoUrlReactions:
      return fixture(
        id: id,
        text: "Here’s the revised visual. More context at https://inline.chat.",
        entities: urlEntities(in: "Here’s the revised visual. More context at https://inline.chat."),
        reply: true,
        reactions: true,
        attachments: [urlPreview(messageID: id, attachmentIndex: 1, large: false)],
        photo: photoInfo(id: id + 1)
      )
    case .forwardedDocument:
      return fixture(
        id: id,
        text: "The full handoff is attached for everyone.",
        forwarded: true,
        reactions: true,
        document: documentInfo(id: id + 1, fileName: "Product handoff.pdf", mimeType: "application/pdf", size: 1_720_000)
      )
    case .outgoingPhotoLink:
      let text = "Draft shared at https://inline.chat — feedback welcome."
      return fixture(
        id: id,
        text: text,
        outgoing: true,
        status: .sent,
        entities: urlEntities(in: text),
        photo: photoInfo(id: id + 1)
      )
    }
  }

  private static func fixture(
    id: Int64,
    text: String?,
    outgoing: Bool = false,
    status: MessageSendingStatus = .sent,
    entities: MessageEntities? = nil,
    isRtl: Bool = false,
    groupPosition: DeveloperMessagePlaygroundGroupPosition = .isolated,
    reply: Bool = false,
    forwarded: Bool = false,
    reactions: Bool = false,
    attachments: [FullAttachment] = [],
    photo: PhotoInfo? = nil,
    video: VideoInfo? = nil,
    document: DocumentInfo? = nil,
    voice: Bool = false,
    richContent: InlineProtocol.BlockContent? = nil
  ) -> DeveloperMessageFixture {
    let sender = outgoing ? outgoingUser : incomingUser
    var payload: Client_MessageContentPayload?
    if voice {
      var voiceContent = Client_MessageVoiceContent()
      // A zero remote ID keeps the real voice view render-only: its on-appear auto-download path is not eligible.
      voiceContent.voiceID = 0
      voiceContent.duration = 37
      voiceContent.waveform = Data([8, 18, 28, 14, 34, 22, 42, 16, 31, 20, 38, 12])
      voiceContent.mimeType = "audio/ogg"
      voiceContent.size = 192_000
      var content = Client_MessageContentPayload()
      content.voice = voiceContent
      payload = content
    }

    var message = Message(
      messageId: id,
      fromId: sender.id,
      date: fixtureDate,
      text: text,
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: outgoing,
      status: outgoing ? status : nil,
      repliedToMessageId: reply ? 8_001 : nil,
      forwardFromPeerUserId: forwarded ? forwardedUser.id : nil,
      forwardFromMessageId: forwarded ? 7_001 : nil,
      photoId: photo?.photo.photoId,
      videoId: video?.video.videoId,
      documentId: document?.document.documentId,
      contentPayload: payload,
      entities: entities
    )
    message.globalId = id
    if let richContent {
      message.blockContentPayload = BlockContentPayload(richContent)
    }

    var fullMessage = FullMessage(
      senderInfo: UserInfo(user: sender),
      forwardFromPeerUserInfo: forwarded ? UserInfo(user: forwardedUser) : nil,
      message: message,
      reactions: reactions ? makeReactions(messageID: id) : [],
      repliedToMessage: reply ? makeRepliedToMessage() : nil,
      attachments: attachments
    )
    fullMessage.photoInfo = photo
    fullMessage.videoInfo = video
    fullMessage.documentInfo = document

    return DeveloperMessageFixture(
      message: fullMessage,
      conversation: .space,
      groupPosition: groupPosition,
      isRtl: isRtl
    )
  }

  private static func richFixture(
    id: Int64,
    content: RichCatalogFixture,
    outgoing: Bool = false,
    reactions: Bool = false,
    reply: Bool = false
  ) -> DeveloperMessageFixture {
    fixture(
      id: id,
      text: content.text,
      outgoing: outgoing,
      entities: content.entities,
      reply: reply,
      reactions: reactions,
      richContent: content.blockContent
    )
  }

  private static func richCompactText() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let text = builder.segment("yo Mo")
    return builder.finish(blocks: [paragraphBlock(text)])
  }

  private static func richInlineEntities() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let text = builder.segment(
      "Rich blocks preserve bold, italic, inline code, https://inline.chat, product notes, @Ava, team@example.com, and +1 415 555 0132."
    )
    builder.addEntity(.bold, matching: "bold", in: text)
    builder.addEntity(.italic, matching: "italic", in: text)
    builder.addEntity(.code, matching: "inline code", in: text)
    builder.addEntity(.url, matching: "https://inline.chat", in: text)
    builder.addEntity(.textURL, matching: "product notes", in: text) { entity in
      var textURL = MessageEntity.MessageEntityTextUrl()
      textURL.url = "https://inline.chat/docs"
      entity.textURL = textURL
    }
    builder.addEntity(.mention, matching: "@Ava", in: text) { entity in
      var mention = MessageEntity.MessageEntityMention()
      mention.userID = incomingUser.id
      entity.mention = mention
    }
    builder.addEntity(.email, matching: "team@example.com", in: text)
    builder.addEntity(.phoneNumber, matching: "+1 415 555 0132", in: text)
    return builder.finish(blocks: [paragraphBlock(text)])
  }

  private static func richHierarchy() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Agent research report")
    let introduction = builder.segment("A compact hierarchy makes document rhythm and wrapping easy to inspect.")
    let highlights = builder.segment("Highlights")
    let highlightsBody = builder.segment("The flat text remains authoritative while blocks control structure and presentation.")
    let nextSteps = builder.segment("Next steps")
    let nextStepsBody = builder.segment("Review the layout at narrow and wide canvas widths.")
    let footer = builder.segment("Generated by Hermes Agent · 12:40")
    return builder.finish(blocks: [
      headingBlock(title, level: 1),
      paragraphBlock(introduction),
      headingBlock(highlights, level: 2),
      paragraphBlock(highlightsBody),
      headingBlock(nextSteps, level: 3),
      paragraphBlock(nextStepsBody),
      separatorBlock(),
      footerBlock(footer),
    ])
  }

  private static func richCode() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let introduction = builder.segment("The streaming reconciler keeps compatible nodes at the same recursive path:")
    let code = builder.segment(
      """
      struct StreamState {
        var revision: Int
        var blocks: [Block]
      }

      state.revision += 1
      """
    )
    let footer = builder.segment("Swift · deterministic fixture")
    return builder.finish(blocks: [
      paragraphBlock(introduction),
      codeBlock(code, language: "swift"),
      footerBlock(footer),
    ])
  }

  private static func richPlainCode() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let introduction = builder.segment("A language label is optional; copy and line numbers remain available:")
    let code = builder.segment(
      """
      status = await agent.run(task)
      if status.isComplete {
        publish(status.blocks)
      }
      """
    )
    return builder.finish(blocks: [paragraphBlock(introduction), codeBlock(code)])
  }

  private static func richCodeLanguages() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let introduction = builder.segment("The production highlighter covers the common agent-output languages:")
    let fixtures: [(language: String, source: String)] = [
      ("swift", "let answer: Int = 42"),
      ("typescript", "const answer: number = await agent.run()"),
      ("python", "answer: int = await agent.run()"),
      ("bash", "result=$(inline messages list --limit 10)"),
      ("html", "<section class=\"answer\">Ready</section>"),
      ("css", ".answer { color: var(--accent); }"),
      ("json", "{\"status\": \"ready\", \"count\": 10}"),
      ("yaml", "status: ready\ncount: 10"),
      ("go", "answer := awaitResult(ctx)"),
      ("rust", "let answer: usize = results.len();"),
    ]
    var blocks = [paragraphBlock(introduction)]
    for fixture in fixtures {
      blocks.append(codeBlock(builder.segment(fixture.source), language: fixture.language))
    }
    return builder.finish(blocks: blocks)
  }

  private static func richChecklist() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Release checks")
    let completed = builder.segment("Parse the agent response into blocks")
    let pending = builder.segment("Verify the final visual pass")
    let completeAgain = builder.segment("Keep flat text available to older clients")
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      checklistBlock(items: [
        (true, [paragraphBlock(completed)]),
        (false, [paragraphBlock(pending)]),
        (true, [paragraphBlock(completeAgain)]),
      ]),
    ])
  }

  static func makeStreaming(revision: Int) -> DeveloperMessageFixture {
    let id = Int64(30_000 + catalogIndex(.richStreaming) * 100)
    return richFixture(
      id: id,
      content: richStreaming(revision: min(max(0, revision), streamingRevisionCount - 1))
    )
  }

  private static func richStreaming(revision: Int) -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Live agent response")
    let introductionText = switch revision {
      case 0: "The first partial snapshot has arrived."
      case 1: "The agent is extending the same message with structured findings."
      case 2: "Code and another list item arrived without replacing compatible views."
      default: "The final snapshot keeps local disclosure state while completing the answer."
    }
    let introduction = builder.segment(introductionText)
    let summary = builder.segment(revision == streamingRevisionCount - 1 ? "Streaming complete" : "Working through the request")
    let body = builder.segment("This disclosure keeps the same recursive path across every revision.")
    let first = builder.segment("Preserve compatible node views")
    let second = builder.segment("Animate measured frame changes")
    let third = builder.segment("Retain nested interaction state")
    let code = builder.segment("renderer.apply(snapshot: revision)")
    let footer = builder.segment("Stream revision \(revision + 1) of \(streamingRevisionCount)")

    let allItems = [first, second, third]
    let visibleItemCount = min(revision + 1, allItems.count)
    var children: [InlineProtocol.Block] = [
      paragraphBlock(body),
      listBlock(
        kind: .unordered,
        items: allItems.prefix(visibleItemCount).map { [paragraphBlock($0)] }
      ),
    ]
    if revision >= 2 {
      children.append(codeBlock(code, language: "swift"))
    }
    let disclosure = disclosureBlock(
      summary: summary,
      kind: revision == streamingRevisionCount - 1 ? .default : .progress,
      initiallyOpen: true,
      children: children
    )
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      paragraphBlock(introduction),
      disclosure,
      footerBlock(footer),
    ])
  }

  private static func richNestedLists() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Release checklist")
    let first = builder.segment("Verify the existing flat text and entities.")
    let second = builder.segment("Exercise renderer state across a streamed update.")
    let nestedFirst = builder.segment("Preserve the open disclosure state.")
    let nestedSecond = builder.segment("Preserve the horizontal album offset.")
    let third = builder.segment("Keep failure isolated to the rich projection.")
    let nested = listBlock(
      kind: .ordered,
      start: 3,
      items: [
        [paragraphBlock(nestedFirst)],
        [paragraphBlock(nestedSecond)],
      ]
    )
    let list = listBlock(
      kind: .unordered,
      items: [
        [paragraphBlock(first)],
        [paragraphBlock(second), nested],
        [paragraphBlock(third)],
      ]
    )
    return builder.finish(blocks: [headingBlock(title, level: 2), list])
  }

  private static func richDisclosures() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let outerSummary = builder.segment("Implementation details")
    let outerBody = builder.segment("The outer disclosure begins expanded and contains another disclosure.")
    let innerSummary = builder.segment("Show reconciliation pseudocode")
    let innerCode = builder.segment("reuse[path] = previous.kind == current.kind")
    let closedSummary = builder.segment("Deferred production gates")
    let closedBody = builder.segment("Visual, tactile, accessibility, and fast-scroll acceptance remain explicit gates.")

    let nested = disclosureBlock(
      summary: innerSummary,
      initiallyOpen: true,
      children: [codeBlock(innerCode, language: "swift")]
    )
    let outer = disclosureBlock(
      summary: outerSummary,
      initiallyOpen: true,
      children: [paragraphBlock(outerBody), nested]
    )
    let closed = disclosureBlock(
      summary: closedSummary,
      initiallyOpen: false,
      children: [paragraphBlock(closedBody)]
    )
    return builder.finish(blocks: [outer, closed])
  }

  private static func richProgressDisclosure() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let summary = builder.segment("Working through the implementation")
    let body = builder.segment("The progress title uses the live shimmer treatment while the disclosure is visible.")
    let first = builder.segment("Inspect protocol ranges")
    let second = builder.segment("Reconcile the next snapshot")
    let code = builder.segment("await renderer.apply(nextRevision)")
    let progress = disclosureBlock(
      summary: summary,
      kind: .progress,
      initiallyOpen: true,
      children: [
        paragraphBlock(body),
        listBlock(kind: .unordered, items: [
          [paragraphBlock(first)],
          [paragraphBlock(second)],
        ]),
        codeBlock(code, language: "swift"),
      ]
    )
    return builder.finish(blocks: [progress])
  }

  private static func richPendingImage() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Image upload")
    let body = builder.segment("The placeholder reserves the final landscape aspect ratio while the server publishes the photo.")
    let alt = builder.segment("Product dashboard preview")
    let footer = builder.segment("Pending · 1600 × 900")
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      paragraphBlock(body),
      imageBlock(pendingImage(alt: alt, width: 1_600, height: 900)),
      footerBlock(footer),
    ])
  }

  private static func richUnknownImage() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let alt = builder.segment("Image pending without dimensions")
    let pending = BlockImagePending()
    var image = BlockImage()
    image.alt = alt
    image.pending = pending
    return builder.finish(blocks: [imageBlock(image)])
  }

  private static func richReadyImage(isReady: Bool) -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Ready image block")
    let body = builder.segment("The Playground prepares a deterministic local cache entry, then republishes this same image path as ready.")
    let alt = builder.segment("Inline application artwork")
    let footer = builder.segment(isReady ? "Ready · local production photo view" : "Preparing local ready-photo fixture…")
    let image = isReady
      ? readyImage(
        alt: alt,
        photoID: DeveloperRichMediaFixtureCache.photoID,
        width: 384,
        height: 384
      )
      : pendingImage(alt: alt, width: 384, height: 384)
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      paragraphBlock(body),
      imageBlock(image),
      footerBlock(footer),
    ])
  }

  private static func richUnavailableImage() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let body = builder.segment("An invalid image remains visible as a stable tile instead of collapsing the message.")
    let alt = builder.segment("Unavailable portrait reference")
    let footer = builder.segment("Unavailable · original space preserved")
    return builder.finish(blocks: [
      paragraphBlock(body),
      imageBlock(unavailableImage(alt: alt, width: 900, height: 1_200)),
      footerBlock(footer),
    ])
  }

  private static func richAlbum(hasReadyPhoto: Bool) -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Visual references")
    let body = builder.segment("Two local photos, a repeated occurrence, an unavailable image, a missing local file, and a pending image exercise album navigation and failure handling without network requests.")
    let first = builder.segment("Inline application artwork")
    let second = builder.segment("Inline logo artwork")
    let third = builder.segment("Repeated application artwork")
    let fourth = builder.segment("Unavailable architecture diagram")
    let fifth = builder.segment("Intentionally missing local image")
    let sixth = builder.segment("Tall mobile capture")
    let images = [
      hasReadyPhoto
        ? readyImage(
          alt: first,
          photoID: DeveloperRichMediaFixtureCache.photoID,
          width: 384,
          height: 384
        )
        : pendingImage(alt: first, width: 384, height: 384),
      hasReadyPhoto
        ? readyImage(alt: second, photoID: DeveloperRichMediaFixtureCache.logoPhotoID, width: 148, height: 130)
        : pendingImage(alt: second, width: 148, height: 130),
      hasReadyPhoto
        ? readyImage(alt: third, photoID: DeveloperRichMediaFixtureCache.photoID, width: 384, height: 384)
        : pendingImage(alt: third, width: 384, height: 384),
      unavailableImage(alt: fourth, width: 1_400, height: 900),
      hasReadyPhoto
        ? readyImage(alt: fifth, photoID: DeveloperRichMediaFixtureCache.missingPhotoID, width: 1_800, height: 800)
        : pendingImage(alt: fifth, width: 1_800, height: 800),
      pendingImage(alt: sixth, width: 800, height: 1_400),
    ]
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      paragraphBlock(body),
      albumBlock(images),
    ])
  }

  private static func richAgentAnswer() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let title = builder.segment("Rich content implementation")
    let introduction = builder.segment(
      "The durable first pass is ready for review. Read the protocol notes at https://inline.chat/docs."
    )
    builder.addEntity(.bold, matching: "durable first pass", in: introduction)
    builder.addEntity(.url, matching: "https://inline.chat/docs", in: introduction)
    let progressSummary = builder.segment("Verifying the final integration")
    let progressBody = builder.segment("The existing message renderer remains the only presentation path.")
    let first = builder.segment("Measure the block plan once.")
    let second = builder.segment("Reuse compatible views by recursive path.")
    let code = builder.segment("guard revision >= previousRevision else { return }")
    let footer = builder.segment("Generated by OpenClaw · sources checked")
    let progress = disclosureBlock(
      summary: progressSummary,
      kind: .progress,
      initiallyOpen: true,
      children: [
        paragraphBlock(progressBody),
        listBlock(kind: .unordered, items: [
          [paragraphBlock(first)],
          [paragraphBlock(second)],
        ]),
        codeBlock(code, language: "swift"),
      ]
    )
    return builder.finish(blocks: [
      headingBlock(title, level: 1),
      paragraphBlock(introduction),
      progress,
      footerBlock(footer),
    ])
  }

  private static func richRTLBlocks() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    var title = builder.segment("گزارش پیشرفت عامل")
    title.isRtl = true
    var body = builder.segment("هر بلوک جهت خودش را دارد و پیام می\u{200C}تواند محتوای فارسی و English را کنار هم نگه دارد.")
    body.isRtl = true
    let first = builder.segment("بررسی قرارداد و محدوده\u{200C}های متن")
    let second = builder.segment("حفظ وضعیت محلی هنگام پخش زنده")
    let summary = builder.segment("جزئیات پیاده\u{200C}سازی")
    let disclosureBody = builder.segment("کد همچنان چپ\u{200C}به\u{200C}راست است، اما عنوان و محتوای این گروه راست\u{200C}به\u{200C}چپ هستند.")
    let code = builder.segment("let direction: WritingDirection = .leftToRight")
    let english = builder.segment("This final paragraph returns to LTR without changing the whole message.")
    return builder.finish(blocks: [
      headingBlock(title, level: 2),
      paragraphBlock(body),
      listBlock(
        kind: .unordered,
        items: [[paragraphBlock(first)], [paragraphBlock(second)]],
        isRTL: true
      ),
      disclosureBlock(
        summary: summary,
        initiallyOpen: true,
        children: [paragraphBlock(disclosureBody), codeBlock(code, language: "swift")],
        isRTL: true
      ),
      paragraphBlock(english),
    ])
  }

  private static func richQuote() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let introduction = builder.segment("A quote stays structural instead of appearing as a literal greater-than character.")
    let first = builder.segment("Build the smallest durable slice, then make every deferred boundary explicit.")
    builder.addEntity(.italic, matching: "smallest durable slice", in: first)
    let second = builder.segment("Streaming should preserve view identity and local interaction state.")
    let footer = builder.segment("Implementation note · quoted from the project ground truth")
    return builder.finish(blocks: [
      paragraphBlock(introduction),
      quoteBlock(children: [paragraphBlock(first), paragraphBlock(second)], isRTL: false),
      footerBlock(footer),
    ])
  }

  private static func richTable() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let introduction = builder.segment("A wide table uses precomputed cell geometry and a custom horizontal pan surface.")
    let name = builder.segment("Block")
    let owner = builder.segment("Owner")
    let state = builder.segment("State")
    let note = builder.segment("Notes")
    let paragraph = builder.segment("Paragraph")
    let renderer = builder.segment("Text node")
    let stable = builder.segment("Stable")
    let paragraphNote = builder.segment("Inline entities and per-block direction")
    let code = builder.segment("Code")
    let codeView = builder.segment("Code node")
    let ready = builder.segment("Ready")
    let codeNote = builder.segment("Copy header, language, and line numbers")
    let image = builder.segment("Image")
    let imageView = builder.segment("Image node")
    let pending = builder.segment("Pending")
    let imageNote = builder.segment("Aspect ratio remains reserved without flicker")
    builder.addEntity(.bold, matching: "precomputed cell geometry", in: introduction)
    let footer = builder.segment(
      "Generated by the message playground · this deliberately long footer verifies wrapping without ellipsis while short footers may share the timestamp row."
    )
    return builder.finish(blocks: [
      paragraphBlock(introduction),
      tableBlock(
        rows: [
          [name, owner, state, note],
          [paragraph, renderer, stable, paragraphNote],
          [code, codeView, ready, codeNote],
          [image, imageView, pending, imageNote],
        ],
        alignments: [.left, .left, .center, .left],
        isRTL: false
      ),
      footerBlock(footer),
    ])
  }

  private static func paragraphBlock(_ text: BlockText) -> InlineProtocol.Block {
    var block = InlineProtocol.Block()
    block.paragraph = text
    return block
  }

  private static func headingBlock(_ text: BlockText, level: UInt32) -> InlineProtocol.Block {
    var heading = BlockHeading()
    heading.text = text
    heading.level = level
    var block = InlineProtocol.Block()
    block.heading = heading
    return block
  }

  private static func codeBlock(_ text: BlockText, language: String? = nil) -> InlineProtocol.Block {
    var code = BlockCode()
    code.text = text
    if let language {
      code.language = language
    }
    var block = InlineProtocol.Block()
    block.code = code
    return block
  }

  private static func listBlock(
    kind: BlockList.Kind,
    start: Int64? = nil,
    items: [[InlineProtocol.Block]],
    isRTL: Bool? = nil
  ) -> InlineProtocol.Block {
    var list = BlockList()
    list.kind = kind
    if let start {
      list.start = start
    }
    if let isRTL {
      list.isRtl = isRTL
    }
    list.items = items.map { children in
      var item = BlockListItem()
      item.children = children
      return item
    }
    var block = InlineProtocol.Block()
    block.list = list
    return block
  }

  private static func checklistBlock(
    items: [(checked: Bool, children: [InlineProtocol.Block])]
  ) -> InlineProtocol.Block {
    var list = BlockList()
    list.kind = .unordered
    list.items = items.map { value in
      var item = BlockListItem()
      item.children = value.children
      item.checked = value.checked
      return item
    }
    var block = InlineProtocol.Block()
    block.list = list
    return block
  }

  private static func separatorBlock() -> InlineProtocol.Block {
    var block = InlineProtocol.Block()
    block.separator = BlockSeparator()
    return block
  }

  private static func footerBlock(_ text: BlockText) -> InlineProtocol.Block {
    var block = InlineProtocol.Block()
    block.footer = text
    return block
  }

  private static func disclosureBlock(
    summary: BlockText,
    kind: BlockDisclosure.Kind = .default,
    initiallyOpen: Bool? = nil,
    children: [InlineProtocol.Block],
    isRTL: Bool? = nil
  ) -> InlineProtocol.Block {
    var disclosure = BlockDisclosure()
    disclosure.summary = summary
    disclosure.kind = kind
    if let initiallyOpen {
      disclosure.initiallyOpen = initiallyOpen
    }
    if let isRTL {
      disclosure.isRtl = isRTL
    }
    disclosure.children = children
    var block = InlineProtocol.Block()
    block.disclosure = disclosure
    return block
  }

  private static func quoteBlock(
    children: [InlineProtocol.Block],
    isRTL: Bool? = nil
  ) -> InlineProtocol.Block {
    var quote = BlockQuote()
    quote.children = children
    if let isRTL {
      quote.isRtl = isRTL
    }
    var block = InlineProtocol.Block()
    block.quote = quote
    return block
  }

  private static func tableBlock(
    rows: [[BlockText]],
    alignments: [BlockTable.Alignment],
    isRTL: Bool? = nil
  ) -> InlineProtocol.Block {
    var table = BlockTable()
    table.rows = rows.map { cells in
      var row = BlockTableRow()
      row.cells = cells
      return row
    }
    table.alignments = alignments
    if let isRTL {
      table.isRtl = isRTL
    }
    var block = InlineProtocol.Block()
    block.table = table
    return block
  }

  private static func imageBlock(_ image: BlockImage) -> InlineProtocol.Block {
    var block = InlineProtocol.Block()
    block.image = image
    return block
  }

  private static func albumBlock(_ images: [BlockImage]) -> InlineProtocol.Block {
    var album = BlockAlbum()
    album.images = images
    var block = InlineProtocol.Block()
    block.album = album
    return block
  }

  private static func pendingImage(alt: BlockText, width: UInt32, height: UInt32) -> BlockImage {
    var dimensions = BlockImageDimensions()
    dimensions.width = width
    dimensions.height = height
    var pending = BlockImagePending()
    pending.dimensions = dimensions
    var image = BlockImage()
    image.alt = alt
    image.pending = pending
    return image
  }

  private static func readyImage(
    alt: BlockText,
    photoID: Int64,
    width: Int32,
    height: Int32
  ) -> BlockImage {
    var size = InlineProtocol.PhotoSize()
    size.type = DeveloperRichMediaFixtureCache.sizeType
    size.w = width
    size.h = height
    size.size = 112_000
    // The protocol's source field carries a local URL only in this developer
    // fixture. Production photo projection/eligibility stays unchanged.
    size.cdnURL = DeveloperRichMediaFixtureCache.cacheURL(for: photoID).absoluteString
    var photo = InlineProtocol.Photo()
    photo.id = photoID
    photo.date = Int64(fixtureDate.timeIntervalSince1970)
    photo.format = .png
    photo.sizes = [size]
    var image = BlockImage()
    image.alt = alt
    image.ready = photo
    return image
  }

  private static func unavailableImage(alt: BlockText, width: UInt32, height: UInt32) -> BlockImage {
    var dimensions = BlockImageDimensions()
    dimensions.width = width
    dimensions.height = height
    var unavailable = BlockImageUnavailable()
    unavailable.dimensions = dimensions
    var image = BlockImage()
    image.alt = alt
    image.unavailable = unavailable
    return image
  }

  private static func richMath() -> RichCatalogFixture {
    var builder = RichCatalogTextBuilder()
    let heading = builder.segment("Native math: source is preserved")
    let formulas = [
      #"\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#,
      #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#,
      (1...12).map { "\\frac{a_{\($0)}}{b_{\($0)}}" }.joined(separator: "+"),
      #"\notAnInlineMathCommand{x}"#,
    ]
    let inlineFormula = #"\frac{x_1}{y}+\sqrt{z}"#
    let inlineText = "Before " + inlineFormula + " after 😀."
    let inlineSpan = builder.segment(inlineText)
    let tableHeader = builder.segment("Formula in a table cell")
    let tableFormula = builder.segment(#"e^{i\pi}+1=0"#)
    builder.addEntity(.math, matching: inlineFormula, in: inlineSpan)
    builder.addEntity(.math, matching: #"e^{i\pi}+1=0"#, in: tableFormula)
    let ranges = formulas.map { formula in
      let range = builder.segment(formula)
      builder.addEntity(.math, matching: formula, in: range)
      return range
    }
    return builder.finish(blocks: [
      .with { $0.paragraph = heading },
      .with { $0.paragraph = inlineSpan },
      .with { $0.table = .with {
        $0.rows = [.with { $0.cells = [tableHeader] }, .with { $0.cells = [tableFormula] }]
        $0.alignments = [.left]
      } },
    ] + ranges.map { range in
      .with { $0.math = range }
    })
  }

  private struct RichCatalogFixture {
    var text: String
    var entities: MessageEntities?
    var blockContent: InlineProtocol.BlockContent
  }

  private struct RichCatalogTextBuilder {
    private(set) var text = ""
    private var entities: [MessageEntity] = []

    mutating func segment(_ value: String) -> BlockText {
      if !text.isEmpty {
        text.append("\n")
      }
      let offset = (text as NSString).length
      text.append(value)
      var range = BlockText()
      range.offset = Int64(offset)
      range.length = Int64((value as NSString).length)
      return range
    }

    mutating func addEntity(
      _ type: MessageEntity.TypeEnum,
      matching substring: String,
      in range: BlockText,
      update: ((inout MessageEntity) -> Void)? = nil
    ) {
      let value = text as NSString
      let segmentRange = NSRange(location: Int(range.offset), length: Int(range.length))
      let segment = value.substring(with: segmentRange) as NSString
      let localRange = segment.range(of: substring)
      guard localRange.location != NSNotFound else {
        assertionFailure("Missing rich fixture entity substring: \(substring)")
        return
      }
      var entity = MessageEntity()
      entity.type = type
      entity.offset = range.offset + Int64(localRange.location)
      entity.length = Int64(localRange.length)
      update?(&entity)
      entities.append(entity)
    }

    func finish(blocks: [InlineProtocol.Block]) -> RichCatalogFixture {
      var blockContent = InlineProtocol.BlockContent()
      blockContent.blocks = blocks
      let entityPayload: MessageEntities? = if entities.isEmpty {
        nil
      } else {
        MessageEntities.with { $0.entities = entities }
      }
      return RichCatalogFixture(
        text: text,
        entities: entityPayload,
        blockContent: blockContent
      )
    }
  }

  private static func photoInfo(id: Int64) -> PhotoInfo {
    PhotoInfo(
      photo: Photo(photoId: id, date: fixtureDate, format: .png),
      sizes: [
        PhotoSize(
          photoId: id,
          type: "f",
          width: 384,
          height: 384,
          size: 112_000,
          localPath: localImagePath
        ),
      ]
    )
  }

  private static func videoInfo(id: Int64) -> VideoInfo {
    var proto = InlineProtocol.Video()
    proto.id = id
    proto.date = Int64(fixtureDate.timeIntervalSince1970)
    proto.w = 1280
    proto.h = 720
    proto.duration = 24
    proto.size = 8_400_000
    proto.hasAudio_p = true
    return VideoInfo(
      video: InlineKit.Video.from(proto: proto, localPhotoId: nil),
      photoInfo: photoInfo(id: id + 1)
    )
  }

  private static func documentInfo(
    id: Int64,
    fileName: String,
    mimeType: String,
    size: Int
  ) -> DocumentInfo {
    var proto = InlineProtocol.Document()
    proto.id = id
    proto.date = Int64(fixtureDate.timeIntervalSince1970)
    proto.fileName = fileName
    proto.mimeType = mimeType
    proto.size = Int32(size)
    return DocumentInfo(document: InlineKit.Document.from(proto: proto))
  }

  private static func urlPreview(
    messageID: Int64,
    attachmentIndex: Int64,
    large: Bool
  ) -> FullAttachment {
    let previewID = messageID + 20 + attachmentIndex
    let preview = UrlPreview(
      id: previewID,
      url: attachmentIndex == 1 ? "https://inline.chat" : "https://inline.chat/docs",
      siteName: "Inline",
      title: attachmentIndex == 1 ? "A calmer place to work together" : "Inline product documentation",
      description: "Threads, messages, files, and agents in one focused workspace.",
      photoId: large ? previewID + 1 : nil,
      duration: nil,
      displayUrl: attachmentIndex == 1 ? "inline.chat" : "inline.chat/docs",
      provider: "Inline",
      mediaKind: large ? "image" : nil,
      hasLargeMedia: large,
      showLargeMedia: large
    )
    var attachment = Attachment(
      messageId: messageID,
      externalTaskId: nil,
      urlPreviewId: previewID,
      attachmentId: previewID + 10
    )
    attachment.id = previewID + 10
    return FullAttachment(
      attachment: attachment,
      urlPreview: preview,
      photoInfo: large ? photoInfo(id: previewID + 1) : nil
    )
  }

  private static func urlEntities(in text: String) -> MessageEntities? {
    let url = "https://inline.chat"
    let range = (text as NSString).range(of: url)
    guard range.location != NSNotFound else { return nil }
    var entity = MessageEntity()
    entity.type = .url
    entity.offset = Int64(range.location)
    entity.length = Int64(range.length)
    var entities = MessageEntities()
    entities.entities = [entity]
    return entities
  }

  private static func makeRepliedToMessage() -> EmbeddedMessage {
    var message = Message(
      messageId: 8_001,
      fromId: repliedToUser.id,
      date: fixtureDate.addingTimeInterval(-120),
      text: "The launch checklist is ready for review.",
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID
    )
    message.globalId = 8_001
    return EmbeddedMessage(message: message, senderInfo: UserInfo(user: repliedToUser))
  }

  private static func makeReactions(messageID: Int64) -> [FullReaction] {
    [
      fullReaction(id: 1, messageID: messageID, user: incomingUser, emoji: "👍", offset: 0),
      fullReaction(id: 2, messageID: messageID, user: repliedToUser, emoji: "👍", offset: 1),
      fullReaction(id: 3, messageID: messageID, user: forwardedUser, emoji: "🎉", offset: 2),
    ]
  }

  private static func fullReaction(
    id: Int64,
    messageID: Int64,
    user: InlineKit.User,
    emoji: String,
    offset: TimeInterval
  ) -> FullReaction {
    FullReaction(
      reaction: Reaction(
        id: id,
        messageId: messageID,
        userId: user.id,
        emoji: emoji,
        date: fixtureDate.addingTimeInterval(offset),
        chatId: chatID
      ),
      userInfo: UserInfo(user: user)
    )
  }

  private static func catalogIndex(_ kind: DeveloperMessageCatalogKind) -> Int {
    let all: [DeveloperMessageCatalogKind] = [
      .shortIncoming, .longOutgoing, .emoji, .linkedText, .rtl,
      .richCompactText, .richInlineEntities, .richHierarchy, .richCode, .richCodeLanguages, .richPlainCode,
      .richStreaming, .richNestedLists, .richChecklist,
      .richDisclosures, .richProgressDisclosure, .richPendingImage, .richUnknownImage, .richReadyImage,
      .richUnavailableImage, .richAlbum, .richAgentAnswer,
      .richRTLBlocks, .richQuote, .richTable,
      .groupStart, .groupMiddle, .groupEnd, .reply, .forwarded, .reactions, .sending, .failed,
      .compactUrlPreview, .largeUrlPreview, .multipleUrlPreviews,
      .photo, .photoCaption, .video, .pdf, .archive, .voice,
      .replyPhotoUrlReactions, .forwardedDocument, .outgoingPhotoLink, .richMath,
    ]
    return all.firstIndex(of: kind) ?? 0
  }

  private static let localImagePath = DeveloperRichMediaFixtureCache.sourceURL.path

  private static let incomingUser = User(
    id: 7_001,
    email: "ava@example.com",
    firstName: "Ava",
    lastName: "Lin"
  )

  private static let outgoingUser = User(
    id: 7_002,
    email: "mo@example.com",
    firstName: "Mo"
  )

  private static let repliedToUser = User(
    id: 7_003,
    email: "sam@example.com",
    firstName: "Sam",
    lastName: "Rivera"
  )

  private static let forwardedUser = User(
    id: 7_004,
    email: "noor@example.com",
    firstName: "Noor",
    lastName: "Azadi"
  )
}

enum DeveloperRichMediaFixtureCache {
  // A dedicated size type keeps fixture cache files separate from production
  // photo sizes, including when their IDs happen to coincide.
  static let sizeType = "playground-f"
  static let photoID: Int64 = 9_000_000_000_001
  static let logoPhotoID: Int64 = 9_000_000_000_002
  static let missingPhotoID: Int64 = 9_000_000_000_003

  private static let assetsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Assets.xcassets")

  static let sourceURL = assetsURL.appendingPathComponent("AppIcon.imageset/AppIcon-384.png")
  private static let logoSourceURL = assetsURL.appendingPathComponent("inline-logo-bg.imageset/inline-logo-bg.png")

  static func cacheURL(for photoID: Int64) -> URL {
    FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
      .appendingPathComponent("IMG-server-\(photoID)-\(sizeType).png")
  }

  static func prepare() async -> Bool {
    await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      do {
        for (id, source) in [(photoID, sourceURL), (logoPhotoID, logoSourceURL)] {
          let destination = cacheURL(for: id)
          if fileManager.fileExists(atPath: destination.path) { continue }
          guard fileManager.fileExists(atPath: source.path) else { return false }
          try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.copyItem(at: source, to: destination)
        }
        return true
      } catch {
        return false
      }
    }.value
  }
}
#endif
