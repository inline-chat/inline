import AppKit
import Logger
import SwiftUI

public struct MacDevtoolsView: View {
  @State private var store = MacDevtoolsLogStore()

  public init() {}

  public var body: some View {
    @Bindable var store = store

    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Toggle(
            "Capture",
            isOn: Binding(
              get: { store.captureEnabled },
              set: { store.setCaptureEnabled($0) }
            )
          )
          .toggleStyle(.switch)

          Toggle("Follow", isOn: $store.follow)
            .toggleStyle(.checkbox)

          Picker("Level", selection: $store.minimumLevel) {
            ForEach(LogLevel.macDevtoolsMinimumLevels, id: \.self) { level in
              Text(level.macDevtoolsTitle).tag(level)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 130)

          Text(store.countText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(1)

          Spacer(minLength: 8)

          Button {
            store.copySelectedEntry()
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .labelStyle(.iconOnly)
          .help("Copy selected log")
          .disabled(store.selectedEntry == nil)

          Button {
            store.exportReport()
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }
          .labelStyle(.iconOnly)
          .help("Export report")
        }

        TextField("Filter", text: $store.filter)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: .infinity)
      }
      .padding(12)

      Divider()

      HSplitView {
        logList
          .frame(minWidth: 320)

        MacDevtoolsLogDetailView(
          entry: store.selectedEntry,
          rawText: store.selectedEntry.map(store.rawText(for:)) ?? ""
        )
        .frame(minWidth: 220, idealWidth: 320)
      }

      if let statusMessage = store.statusMessage {
        Divider()
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
      }
    }
    .frame(minWidth: 540, minHeight: 360)
    .task {
      store.start()
    }
    .onDisappear {
      store.stop()
    }
  }

  private var logList: some View {
    @Bindable var store = store

    return VStack(spacing: 0) {
      MacDevtoolsLogHeaderView()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.filteredEntries) { entry in
              MacDevtoolsLogRowView(
                entry: entry,
                isSelected: entry.id == store.selectedID
              )
              .id(entry.id)
              .onTapGesture {
                store.selectedID = entry.id
              }
            }
          }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: store.filteredEntries.last?.id) { _, id in
          guard store.follow, let id else { return }
          proxy.scrollTo(id, anchor: .bottom)
        }
      }
    }
  }
}

private struct MacDevtoolsLogHeaderView: View {
  var body: some View {
    HStack(spacing: 10) {
      Text("Time")
        .frame(width: 74, alignment: .leading)
      Text("Level")
        .frame(width: 62, alignment: .leading)
      Text("Scope")
        .frame(width: 116, alignment: .leading)
      Text("Message")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }
}

private struct MacDevtoolsLogRowView: View {
  let entry: LogEntry
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
        .frame(width: 74, alignment: .leading)
        .foregroundStyle(.secondary)

      Text(entry.level.macDevtoolsTitle.lowercased())
        .frame(width: 62, alignment: .leading)
        .foregroundStyle(levelColor)

      Text(entry.scope)
        .frame(width: 116, alignment: .leading)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Text(entry.message)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }
    .font(.system(.caption, design: .monospaced))
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    .contentShape(Rectangle())
  }

  private var levelColor: Color {
    switch entry.level {
    case .error: .red
    case .warning: .orange
    case .info: .blue
    case .debug: .secondary
    case .trace: .purple
    }
  }
}

private struct MacDevtoolsLogDetailView: View {
  let entry: LogEntry?
  let rawText: String

  var body: some View {
    ScrollView {
      if let entry {
        VStack(alignment: .leading, spacing: 14) {
          detail("Timestamp", entry.timestamp.formatted(.dateTime.year().month().day().hour().minute().second()))
          detail("Level", entry.level.rawValue)
          detail("Scope", entry.scope)
          detail("Source", "\(entry.fileName):\(entry.line)")
          detail("Function", entry.function)
          detail("Process", "\(entry.processIdentifier)")
          detail("Thread", "\(entry.threadIdentifier)")

          VStack(alignment: .leading, spacing: 5) {
            Text("Message")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(entry.message)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          VStack(alignment: .leading, spacing: 5) {
            Text("Raw")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(rawText)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(14)
      } else {
        Text("Select a log entry")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(14)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
