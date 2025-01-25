import SwiftUI

@available(macOS 14.0, *)
struct DevtoolsBarContent: View {
  var body: some View {
    Group {
      // Version info
      VStack(alignment: .leading, spacing: 0) {
        Text("DEVTOOLS")
          .font(.system(.caption, design: .monospaced))
          .padding(.leading, 12)
      }
      Spacer()

      // Metrics
      // Has memory leak
//      Divider()
//      SystemMetricsView()
      Divider()
      // FPS
      FPSView()
        .frame(height: Theme.devtoolsHeight)
    }
  }
}

struct DevtoolsBar: View {
  var body: some View {
    Group {
      if #available(macOS 14.0, *) {
        HStack {
          DevtoolsBarContent()
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.devtoolsHeight)
//        .background(.bar)
        .background(.windowBackground.tertiary)
        //    .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
          Divider()
            .frame(height: 1)
            .offset(y: -1)
        }
        .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .top)))
      } else {
        HStack {
          Text("Devtools Requires macOS 14.0")
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.devtoolsHeight)
      }
    }
    .font(.system(.body, design: .monospaced))
  }
}
