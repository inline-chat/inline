import Foundation
import InlineKit
import SwiftUI

struct DataStorageSettingsDetailView: View {
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload

  var body: some View {
    Form {
      Section {
        AutoDownloadLimitRow(
          title: "Media",
          caps: AutoDownloadLimitCaps.media,
          value: binding(\.mediaMaxMB)
        )
        AutoDownloadLimitRow(
          title: "Files",
          caps: AutoDownloadLimitCaps.files,
          value: binding(\.fileMaxMB)
        )
        AutoDownloadLimitRow(
          title: "Voice Messages",
          caps: AutoDownloadLimitCaps.voice,
          value: binding(\.voiceMaxMB)
        )
      } header: {
        SettingsSectionHeader(
          "Auto-Download",
          subtitle: "Choose local download limits for this Mac. Set a type to Off to disable its auto-download."
        )
      }
    }
    .settingsFormStyle()
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }
}

private struct AutoDownloadLimitRow: View {
  let title: LocalizedStringResource
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
      SettingsRowLabel(title)
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
    value <= 0 ? "Off" : "\(value) MB"
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
