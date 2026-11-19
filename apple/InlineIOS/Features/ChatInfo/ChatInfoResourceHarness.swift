#if DEBUG
import Foundation
import GRDB
import InlineKit
import InlineProtocol
import UIKit

/// Debug builds only: with `--peerinfo-harness --peerinfo-harness-resources`, the first
/// resource tab that opens fills the harness's "eng" thread (502) with 1,500 photos and
/// videos, plus files, voice messages and links, across about fifteen months. Images are
/// generated JPEGs on disk, so scrolling can be checked at volume with no server.
enum ChatInfoResourceHarness {
  static let chatId: Int64 = 502

  @MainActor private static var seeding: Task<Void, Never>?

  static var isRequested: Bool {
    PeerInfoDebugFixture.isRequested && CommandLine.arguments.contains("--peerinfo-harness-resources")
  }

  @MainActor
  static func seedIfRequested() async {
    guard isRequested else { return }
    let task = seeding ?? Task.detached(priority: .userInitiated) { await seed() }
    seeding = task
    await task.value
  }

  private static func seed() async {
    let images = makeImages(count: 24)
    let now = Int64(Date().timeIntervalSince1970)
    let hour: Int64 = 3_600
    try? await AppDatabase.shared.dbWriter.write { db in
      guard try Message.filter(Message.Columns.chatId == chatId).filter(Message.Columns.messageId >= 10_000)
        .fetchCount(db) == 0
      else { return }

      func save(_ id: Int64, date: Int64, _ fill: (inout InlineProtocol.Message) -> Void) throws {
        var message = InlineProtocol.Message.with {
          $0.id = id
          $0.chatID = chatId
          $0.fromID = id.isMultiple(of: 3) ? PeerInfoDebugFixture.me : 2
          $0.out = id.isMultiple(of: 3)
          $0.peerID = .with { $0.chat.chatID = chatId }
          $0.date = date
          $0.rev = 1
        }
        fill(&message)
        _ = try Message.save(db, protocolMessage: message, materializeMissingReferences: true)
      }

      for index in 0 ..< 1_500 {
        let id = Int64(100_000 + index)
        let image = images[index % images.count]
        let photo = InlineProtocol.Photo.with {
          $0.id = Int64(200_000 + index)
          $0.date = now
          $0.format = .jpeg
          $0.sizes = [.with {
            $0.type = "f"
            $0.w = Int32(image.size.width)
            $0.h = Int32(image.size.height)
            $0.size = 400_000
            $0.cdnURL = image.url.absoluteString
          }]
        }
        try save(id, date: now - Int64(index) * 7 * hour) { message in
          if index % 7 == 3 {
            message.media.video.video = .with {
              $0.id = Int64(300_000 + index)
              $0.date = now
              $0.w = Int32(image.size.width)
              $0.h = Int32(image.size.height)
              $0.duration = Int32(5 + index % 400)
              $0.photo = photo
            }
          } else {
            message.media.photo.photo = photo
          }
        }
      }

      let files: [(String, String, Int32)] = [
        ("Q3 roadmap.pdf", "application/pdf", 2_400_000),
        ("Design review notes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 84_000),
        ("Usage export.csv", "text/csv", 1_200_000),
        ("Launch deck.key", "application/x-iwork-keynote-sffkey", 18_000_000),
        ("logs-2026-11-02.zip", "application/zip", 46_000_000),
        ("RealtimeClient.swift", "text/x-swift", 22_000),
        ("onboarding-v3.mov", "video/quicktime", 120_000_000),
        ("A very long file name that keeps going well past the edge of the row.pdf", "application/pdf", 640_000),
      ]
      for index in 0 ..< 160 {
        let file = files[index % files.count]
        try save(Int64(400_000 + index), date: now - Int64(index) * 61 * hour) { message in
          message.media.document.document = .with {
            $0.id = Int64(500_000 + index)
            $0.fileName = file.0
            $0.mimeType = file.1
            $0.size = file.2
            $0.date = now
          }
        }
      }

      for index in 0 ..< 90 {
        try save(Int64(600_000 + index), date: now - Int64(index) * 97 * hour) { message in
          message.media.voice.voice = .with {
            $0.id = Int64(700_000 + index)
            $0.duration = Int32(3 + index * 7 % 180)
            $0.size = 40_000
            $0.mimeType = "audio/ogg"
            $0.waveform = Data((0 ..< 64).map { UInt8(($0 * 37 + index * 11) % 31) })
          }
        }
      }

      let links: [(String, String?, String?)] = [
        ("https://developer.apple.com/documentation/swiftui/lazyvgrid", "LazyVGrid", "A container view that arranges its child views in a grid that grows vertically."),
        ("https://inline.chat/docs", "Inline Docs", "Guides for spaces, threads, bots and the API."),
        ("https://github.com/kean/Nuke/releases", nil, nil),
        ("https://www.figma.com/file/abc/Chat-info", "Chat info – Figma", nil),
      ]
      for index in 0 ..< 120 {
        let link = links[index % links.count]
        let id = Int64(800_000 + index)
        try save(id, date: now - Int64(index) * 73 * hour) { message in
          message.message = index.isMultiple(of: 5) ? "worth a read \(link.0) and https://inline.chat" : link.0
          message.hasLink_p = true
          if let title = link.1 {
            message.attachments.attachments = [.with {
              $0.id = Int64(900_000 + index)
              $0.urlPreview = .with {
                $0.id = Int64(950_000 + index)
                $0.url = link.0
                $0.title = title
                if let description = link.2 { $0.description_p = description }
              }
            }]
          }
        }
      }
    }
  }

  private static func makeImages(count: Int) -> [(url: URL, size: CGSize)] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peerinfo-harness", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return (0 ..< count).map { index in
      let size = index.isMultiple(of: 3) ? CGSize(width: 1600, height: 1200) : CGSize(width: 1200, height: 1600)
      let url = directory.appendingPathComponent("photo-\(index).jpg")
      if !FileManager.default.fileExists(atPath: url.path) {
        let hue = CGFloat(index) / CGFloat(count)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
          let colors = [
            UIColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor,
            UIColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor,
          ] as CFArray
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
          context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
          let label = "\(index + 1)" as NSString
          label.draw(at: CGPoint(x: 80, y: 80), withAttributes: [
            .font: UIFont.systemFont(ofSize: 220, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
          ])
        }
        try? image.jpegData(compressionQuality: 0.85)?.write(to: url)
      }
      return (url, size)
    }
  }
}
#endif
