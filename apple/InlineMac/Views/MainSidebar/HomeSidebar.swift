import InlineKit
import SwiftUI

struct HomeSidebar: View {
    @EnvironmentObject var ws: WebSocketManager
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var data: DataManager

    @EnvironmentStateObject var model: SpaceListViewModel

    init() {
        _model = EnvironmentStateObject { env in
            SpaceListViewModel(db: env.appDatabase)
        }
    }

    var body: some View {
        List {
            Section("Spaces") {
                ForEach(model.spaces) { space in
                    SpaceItem(space: space)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
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
                SidebarSearchBar()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        })
        .overlay(alignment: .bottom, content: {
            ConnectionStateOverlay()
        })
        .task {
            do {
                let _ = try await data.getSpaces()
            } catch {
                // TODO: handle error? keep on loading? retry? (@mo)
            }
        }
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
                show = true
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
