import SwiftUI

struct EmptySearchView: View {
  let isSearching: Bool

  var body: some View {
    if isSearching {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 4) {
        Text("🔍")
          .font(.largeTitle)
            
          .padding(.bottom, 14)
        Text("Search for people")
          .font(.headline)
            
        Text("Type a username to find someone to add. eg. dena, mo")
            
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 45)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
