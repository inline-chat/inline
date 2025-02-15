import InlineKit
import SwiftUI

struct IntegrationsView: View {
  var body: some View {
    List {
      HStack(alignment: .center) {
        Image("linear-icon")
          .resizable()
          .frame(width: 55, height: 55)
          .clipShape(RoundedRectangle(cornerRadius: 18))
          .padding(.trailing, 6)
        VStack(alignment: .leading) {
          Text("Linear")
            .fontWeight(.semibold)
          Text("Connect your Linear to create issues from messages with AI")
            .foregroundColor(.secondary)
            .font(.caption)
        }
        Spacer()
        Button("Connect") {
          // TODO: Implement Linear integration
        }
        .buttonStyle(.borderless)
      }
    }
//    .listStyle(.plain)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "integrations", placement: .principal) {
        HStack {
          Image(systemName: "app.connected.to.app.below.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Integrations")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }
}
