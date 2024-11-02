import InlineKit
import SwiftUI
import GRDBQuery

struct HomeSidebar: View {
    @EnvironmentObject var ws: WebSocketManager
    @EnvironmentObject var nav: NavigationModel


    var body: some View {
        List {
            NavigationLink(destination: Text("Home")) {
                SpaceItem()
            }
        }
        .toolbar(content: {
            ToolbarItem(placement: .automatic) {
                Menu("New", systemImage: "plus") {
                    Button("New Space") {
                        nav.createSpaceSheetPresented = true
                    }
                }
            }
        })
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, content: {
            VStack(alignment: .leading) {
                SelfUser()
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        })
        .overlay(alignment: .bottom, content: {
            ConnectionStateOverlay()
        })
    }
}

struct ConnectionStateOverlay: View {
    @EnvironmentObject var ws: WebSocketManager
    @State var show = false

    var body: some View {
        Group {
            if show {
                capsule
            }
        }.task {
            if ws.connectionState != .normal {
                show = true;
            }
        }
        .onChange(of: ws.connectionState) { newValue in
            if newValue == .normal {
                Task { @MainActor in
                    try await Task.sleep(for: .seconds(1))
                    if ws.connectionState == .normal {
                        // second check
                        show = false
                    }
                }
            } else {
                show = true
            }
        }
    }

    var capsule: some View {
        HStack {
            Text(textContent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(.capsule(style: .continuous))
        .padding()
    }

    private var textContent: String {
        switch ws.connectionState {
        case .normal:
            return "connected"
        case .connecting:
            return "connecting..."
        case .updating:
            return "updating..."
        }
    }
}

#Preview {
    NavigationSplitView {
        HomeSidebar()
            .previewsEnvironment(.populated)
            .environmentObject(NavigationModel())
    } detail: {
        Text("Welcome.")
    }
}
