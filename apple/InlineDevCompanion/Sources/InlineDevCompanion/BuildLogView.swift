import AppKit
import Foundation
import SwiftUI

struct BuildLogView: View {
  let logURL: URL

  @State private var contents = ""
  @State private var readError: String?
  @State private var followsLatestOutput = true
  private let reader = BuildLogTailReader()

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView([.horizontal, .vertical]) {
        Text(contents.isEmpty ? "Waiting for build output…" : contents)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)

        Color.clear
          .frame(height: 1)
          .id("build-log-bottom")
      }
      .onChange(of: contents) {
        if followsLatestOutput {
          proxy.scrollTo("build-log-bottom", anchor: .bottom)
        }
      }
    }
    .overlay(alignment: .bottomLeading) {
      if let readError {
        Text(readError)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(8)
      }
    }
    .navigationTitle(logURL.lastPathComponent)
    .toolbar {
      ToolbarItem {
        Button(
          followsLatestOutput ? "Pause Auto-scroll" : "Follow Latest Output",
          systemImage: followsLatestOutput ? "pause" : "arrow.down.to.line",
          action: toggleFollowing
        )
        .labelStyle(.iconOnly)
        .help(followsLatestOutput ? "Pause auto-scroll" : "Follow latest output")
      }
      ToolbarItem {
        Button("Show Log in Finder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
        .labelStyle(.iconOnly)
        .help("Show log in Finder")
      }
    }
    .task {
      await monitorLog()
    }
  }

  private func toggleFollowing() {
    followsLatestOutput.toggle()
  }

  private func monitorLog() async {
    while !Task.isCancelled {
      do {
        if let chunk = try await reader.readNewText(from: logURL), !chunk.isEmpty {
          contents.append(chunk)
          if contents.count > 500_000 {
            contents = String(contents.suffix(500_000))
          }
          readError = nil
        }
      } catch {
        readError = error.localizedDescription
      }

      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
    }
  }
}

private actor BuildLogTailReader {
  private var offset: UInt64 = 0

  func readNewText(from url: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    if fileSize < offset {
      offset = 0
    }
    guard fileSize > offset else { return nil }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    offset += UInt64(data.count)
    return String(decoding: data, as: UTF8.self)
  }
}
