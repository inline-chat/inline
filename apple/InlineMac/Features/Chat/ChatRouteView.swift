import InlineKit
import InlineUI
import SwiftUI
import os.signpost

struct ChatRouteView: View {
  let peer: Peer
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  @Environment(\.appDatabase) private var db
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav

  @State private var chatToolbarState = ChatToolbarState()
  @State private var navigationTitle = ""

  private var fallbackTitle: String {
    peer.isThread ? "Chat" : "Direct Message"
  }

  var body: some View {
    if let dependencies {
      let dependencies = dependencies.with(nav3: nav)

      AppKitRouteViewController<ChatViewAppKit>(
        make: {
          let signpostID = OSSignpostID(log: Self.signpostLog)
          var payloadLabel = "cold"
          os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "ChatRouteMakeAppKit",
            signpostID: signpostID,
            "%{public}s",
            String(describing: peer)
          )
          defer {
            os_signpost(
              .end,
              log: Self.signpostLog,
              name: "ChatRouteMakeAppKit",
              signpostID: signpostID,
              "%{public}s",
              payloadLabel
            )
          }

          let preparedPayload = dependencies.nav3ChatOpenPreloader?.consumePreparedPayload(for: peer)
          payloadLabel = preparedPayload == nil ? "cold" : "prepared"
          return ChatViewAppKit(
            peerId: peer,
            preparedPayload: preparedPayload,
            dependencies: dependencies
          )
        },
        dismantle: { controller in
          controller.dispose()
        }
      )
      .ignoresSafeArea(.all, edges: .vertical)
      .id(peer.toString())
      .frame(minWidth: 280)
      .navigationTitle(navigationTitle.isEmpty ? fallbackTitle : navigationTitle)
      .onChange(of: peer.toString(), initial: true) { oldPeer, newPeer in
        navigationTitle = fallbackTitle
        if oldPeer != newPeer {
          chatToolbarState.dismissPresentation()
        }
      }
      .task(id: peer.toString(), priority: .utility) {
        await ensureToolbarParticipantsLoaded(dependencies: dependencies)
      }
      .toolbar {
        let mainItem =
          ToolbarItem(placement: .navigation) {
            ChatRouteTitleBar(peer: peer, db: db, contextSpaceId: nav.selectedSpaceId) { title in
              navigationTitle = title
            }
            .toolbarVisibilityPriority(.high, label: "")
            .id(peer.toString())
            .modifier(ChatToolbarTranslationPresentations(
              peer: peer,
              toolbarState: chatToolbarState,
              anchor: .title,
              listensForPrompt: true
            ))
            .modifier(ChatToolbarParticipantsTitlePresentations(
              peer: peer,
              dependencies: dependencies,
              toolbarState: chatToolbarState
            ))
            .modifier(ChatToolbarNotificationTitlePresentations(
              peer: peer,
              db: dependencies.database,
              toolbarState: chatToolbarState
            ))
            .onDisappear {
              chatToolbarState.handleTitleDisappear()
            }
          }

        if #available(macOS 26.0, *) {
          mainItem.sharedBackgroundVisibility(.hidden)
        } else {
          mainItem
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }

        ToolbarItem {
          ChatToolbarNotificationButton(
            peer: peer,
            db: dependencies.database,
            toolbarState: chatToolbarState
          )
          .id(peer.id)
        }

        if peer.isThread {
          let participantsItem =
            ToolbarItem {
              ChatToolbarParticipantsButton(
                peer: peer,
                dependencies: dependencies,
                toolbarState: chatToolbarState
              )
              .id(peer.toString())
            }

          if #available(macOS 26.0, *) {
            participantsItem.sharedBackgroundVisibility(.hidden)
          } else {
            participantsItem
          }
        }

        if case .user = peer {
          let nudgeItem =
            ToolbarItem {
              NudgeButton(peer: peer)
                .id(peer.id)
            }

          if #available(macOS 26.0, *) {
            nudgeItem.sharedBackgroundVisibility(.hidden)
          } else {
            nudgeItem
          }
        }

        if AppSettings.shared.translationUIEnabled {
          ToolbarItem {
            ChatToolbarTranslationButton(peer: peer, toolbarState: chatToolbarState)
          }
        }

        ToolbarItem {
          ChatToolbarMenuButton(peer: peer, dependencies: dependencies)
            .id(peer.id)
        }
      }
    } else {
      RoutePlaceholderView(
        title: "Missing App Dependencies",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  private func ensureToolbarParticipantsLoaded(dependencies: AppDependencies) async {
    guard case let .thread(chatId) = peer else { return }
    await ChatParticipantsWithMembersViewModel.ensureParticipantsLoaded(
      db: dependencies.database,
      chatId: chatId
    )
  }
}
