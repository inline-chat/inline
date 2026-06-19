import Foundation
import InlineKit
import SwiftUI

struct DataStorageSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload

  var body: some View {
    Form {
      Section {
        autoDownloadLimitRow("Media", caps: AutoDownloadLimitCaps.media, value: binding(\.mediaMaxMB))
        autoDownloadLimitRow("Files", caps: AutoDownloadLimitCaps.files, value: binding(\.fileMaxMB))
        autoDownloadLimitRow("Voice Messages", caps: AutoDownloadLimitCaps.voice, value: binding(\.voiceMaxMB))
      } header: {
        Text("Auto-Download")
      } footer: {
        Text("Set a limit to 0 MB to turn off auto-download for that type. These limits are local to this Mac.")
      }

      Section {
        Toggle(
          "Automatically save downloaded files to Downloads",
          isOn: $appSettings.autoSaveDownloadedFilesToDownloadsFolder
        )
      } header: {
        Text("Downloads")
      } footer: {
        Text("Files are still available inside Inline when this is turned off.")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }

  private func autoDownloadLimitRow(_ title: String, caps: [Int], value: Binding<Int>) -> some View {
    AutoDownloadLimitRow(title: title, caps: caps, value: value)
  }
}

private struct AutoDownloadLimitRow: View {
  let title: String
  let caps: [Int]
  @Binding var value: Int

  @State private var draftIndex: Double?

  var body: some View {
    LabeledContent {
      HStack(spacing: 12) {
        Slider(
          value: sliderBinding,
          in: 0 ... Double(max(caps.count - 1, 0)),
          step: 1
        ) { editing in
          if editing {
            draftIndex = Double(currentIndex)
          } else {
            commitDraft()
          }
        }
        .frame(width: 180)
        .accessibilityLabel(title)
        .accessibilityValue(label(for: selectedValue))

        Text(label(for: selectedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(width: 72, alignment: .trailing)
      }
    } label: {
      Text(title)
    }
  }

  private var sliderBinding: Binding<Double> {
    Binding {
      draftIndex ?? Double(currentIndex)
    } set: { newValue in
      draftIndex = clampedIndex(newValue)
    }
  }

  private var currentIndex: Int {
    nearestIndex(for: value)
  }

  private var selectedValue: Int {
    caps[Int((draftIndex ?? Double(currentIndex)).rounded())]
  }

  private func commitDraft() {
    value = selectedValue
    draftIndex = nil
  }

  private func nearestIndex(for value: Int) -> Int {
    let current = AutoDownloadSettingsManager.clamped(value)
    return caps.indices.min { first, second in
      abs(caps[first] - current) < abs(caps[second] - current)
    } ?? 0
  }

  private func clampedIndex(_ index: Double) -> Double {
    min(max(index.rounded(), 0), Double(max(caps.count - 1, 0)))
  }

  private func label(for value: Int) -> String {
    value <= 0 ? "Off" : ByteCountFormatter.string(fromByteCount: Int64(value) * 1_024 * 1_024, countStyle: .file)
  }
}

private enum AutoDownloadLimitCaps {
  static let media = [0, 5, 10, 25, 50, 100, 250]
  static let files = [0, 5, 10, 25, 50, 100, 250, 500]
  static let voice = [0, 1, 2, 5, 10, 25, 50]
}

#Preview {
  DataStorageSettingsDetailView()
}
