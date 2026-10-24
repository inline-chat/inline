#if DEBUG || DEBUG_BUILD
import SwiftUI

struct DeveloperPlaygroundsView: View {
  var body: some View {
    List {
      Text("No playgrounds yet.")
        .foregroundStyle(.secondary)
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Playgrounds")
    .navigationBarTitleDisplayMode(.inline)
  }
}
#endif
