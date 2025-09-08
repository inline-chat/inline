import InlineKit
import SwiftUI

struct SearchView: View {
  // Inputs
  var isSearching: Bool
  var localResults: [HomeSearchResultItem]
  var globalResults: [GlobalSearchResult]
  var selectedResultIndex: Int
  var isLoading: Bool
  var error: Error?
  var searchQuery: String
  var onSelectLocal: (HomeSearchResultItem) -> Void
  var onSelectRemote: (ApiUser) -> Void

  private var hasAnyResults: Bool {
    !localResults.isEmpty || !globalResults.isEmpty
  }

  var body: some View {
    List {
      if isSearching {
        if hasAnyResults {
          if !localResults.isEmpty {
            Section {
              ForEach(Array(localResults.enumerated()), id: \.element.id) { index, result in
                LocalSearchItem(item: result, highlighted: selectedResultIndex == index) {
                  onSelectLocal(result)
                }
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
              }
            }
          }

          if !globalResults.isEmpty {
            Section("Global Search") {
              ForEach(Array(globalResults.enumerated()), id: \.element.id) { index, result in
                let globalIndex = index + localResults.count
                switch result {
                  case let .users(user):
                    RemoteUserItem(
                      user: user,
                      highlighted: selectedResultIndex == globalIndex,
                      action: { onSelectRemote(user) }
                    )
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
              }
            }
          }
        } else {
          HStack {
            if isLoading {
              ProgressView()
                .progressViewStyle(.circular)
                .tint(.secondary)
            } else if let error {
              Text("Failed to load: \(error.localizedDescription)")
                .font(.body)
                .foregroundStyle(.secondary)
            } else if !searchQuery.isEmpty, !hasAnyResults {
              Image(systemName: "x.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tertiary)
            } else {
              Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tertiary)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .padding()
        }
      }
    }
    .listStyle(.sidebar)
    .listRowBackground(Color.clear)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
