import AppKit
import SwiftUI

struct MacDevtoolsMediaCacheView: View {
  @Bindable var store: MacDevtoolsMediaCacheStore
  @State private var pendingDelete: [MacDevtoolsMediaCacheItem] = []

  var body: some View {
    VStack(spacing: 0) {
      controls

      Divider()

      VSplitView {
        mediaList
          .frame(minHeight: 260)

        MacDevtoolsMediaCacheDetailView(
          item: store.selectedItem,
          selectedItems: store.selectedItems,
          delete: { items in pendingDelete = items }
        )
        .frame(minHeight: 180, idealHeight: 260)
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
    .task {
      store.refresh()
    }
    .onDisappear {
      store.cancelRefresh()
    }
    .confirmationDialog(
      "Prune cached media?",
      isPresented: pendingDeleteBinding
    ) {
      Button(pruneButtonTitle, role: .destructive) {
        store.delete(pendingDelete)
        pendingDelete = []
      }
    } message: {
      Text(pruneMessage)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Picker("Scope", selection: $store.scope) {
          ForEach(MacDevtoolsMediaCacheScope.allCases) { scope in
            Text(scope.title).tag(scope)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 340)

        Text(store.summaryText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Button {
          store.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .help("Refresh cached media")
        .disabled(store.isLoading)

        Button {
          store.copySelectedPaths()
        } label: {
          Label("Copy Path", systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .help("Copy selected file paths")
        .disabled(store.selectedItems.isEmpty)

        Button {
          store.revealSelected()
        } label: {
          Label("Reveal", systemImage: "finder")
        }
        .labelStyle(.iconOnly)
        .help("Reveal selected files in Finder")
        .disabled(store.selectedItems.isEmpty)

        Button {
          store.openSelected()
        } label: {
          Label("Open", systemImage: "arrow.up.right.square")
        }
        .labelStyle(.iconOnly)
        .help("Open selected files")
        .disabled(store.selectedItems.isEmpty)

        Button(role: .destructive) {
          pendingDelete = store.selectedItems
        } label: {
          Label("Prune", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .help("Prune selected cached files")
        .disabled(store.selectedItems.isEmpty)
      }

      TextField("Filter name, path, type, dimensions", text: $store.filter)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
    }
    .padding(12)
  }

  private var mediaList: some View {
    VStack(spacing: 0) {
      MacDevtoolsMediaCacheHeaderView()

      List(selection: $store.selectedIDs) {
        ForEach(store.filteredItems) { item in
          MacDevtoolsMediaCacheRowView(item: item)
          .tag(item.id)
          .id(item.id)
          .listRowInsets(EdgeInsets())
        }
      }
      .listStyle(.plain)
      .background(Color(nsColor: .textBackgroundColor))
      .onChange(of: store.selectedIDs) { _, _ in
        store.updateSelectionFocus()
      }
      .onChange(of: store.filter) { _, _ in
        store.updateSelectionFocus()
      }
      .onChange(of: store.scope) { _, _ in
        store.updateSelectionFocus()
      }
    }
  }

  private var pendingDeleteBinding: Binding<Bool> {
    Binding(
      get: { pendingDelete.isEmpty == false },
      set: { isPresented in
        if isPresented == false {
          pendingDelete = []
        }
      }
    )
  }

  private var pruneButtonTitle: String {
    pendingDelete.count == 1 ? "Prune File" : "Prune \(pendingDelete.count) Files"
  }

  private var pruneMessage: String {
    if pendingDelete.count == 1, let item = pendingDelete.first {
      return item.path
    }

    return "\(pendingDelete.count) cached files selected"
  }
}

private struct MacDevtoolsMediaCacheHeaderView: View {
  var body: some View {
    HStack(spacing: 10) {
      Text("Kind")
        .frame(width: 82, alignment: .leading)
      Text("Name")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Size")
        .frame(width: 86, alignment: .trailing)
      Text("Pixels")
        .frame(width: 82, alignment: .leading)
      Text("Modified")
        .frame(width: 116, alignment: .leading)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }
}

private struct MacDevtoolsMediaCacheRowView: View {
  let item: MacDevtoolsMediaCacheItem

  var body: some View {
    HStack(spacing: 10) {
      Label(item.directory.title, systemImage: item.directory.systemImage)
        .labelStyle(.titleAndIcon)
        .frame(width: 82, alignment: .leading)

      Text(item.fileName)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .truncationMode(.middle)

      Text(item.sizeText)
        .monospacedDigit()
        .frame(width: 86, alignment: .trailing)
        .foregroundStyle(.secondary)

      Text(item.dimensionsText)
        .monospacedDigit()
        .frame(width: 82, alignment: .leading)
        .foregroundStyle(.secondary)

      Text(item.modifiedText)
        .frame(width: 116, alignment: .leading)
        .foregroundStyle(.secondary)
    }
    .font(.system(.caption, design: .monospaced))
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
  }
}

private struct MacDevtoolsMediaCacheDetailView: View {
  let item: MacDevtoolsMediaCacheItem?
  let selectedItems: [MacDevtoolsMediaCacheItem]
  let delete: ([MacDevtoolsMediaCacheItem]) -> Void

  var body: some View {
    ScrollView {
      if let item {
        VStack(alignment: .leading, spacing: 14) {
          if selectedItems.count > 1 {
            Text("\(selectedItems.count) cached files selected")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }

          MacDevtoolsMediaPreview(item: item)

          detail("Name", item.fileName)
          detail("Kind", item.directory.title)
          detail("Type", item.detailTypeText)
          detail("Size", item.sizeText)
          detail("Pixels", item.dimensionsText)
          detail("Modified", item.modifiedText)
          detail("Path", item.path)

          Button(role: .destructive) {
            delete(selectedItems)
          } label: {
            Label(
              selectedItems.count == 1 ? "Prune Cached File" : "Prune Selected Cached Files",
              systemImage: "trash"
            )
          }
        }
        .padding(14)
      } else {
        Text("Select cached media")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct MacDevtoolsMediaPreview: View {
  let item: MacDevtoolsMediaCacheItem

  var body: some View {
    Group {
      if item.isImage, let image = NSImage(contentsOf: item.url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: item.directory.systemImage)
          .font(.system(size: 52))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 260)
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
