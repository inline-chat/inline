//
//  ContentView.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import InlineKit
import SwiftUI

struct ContentView: View {
  @StateObject private var nav = Navigation()
  @StateObject private var onboardingNav = OnboardingNavigation()
  @StateObject var api = ApiClient()
  @StateObject var userData = UserData()
  @Environment(\.auth) private var auth
  @EnvironmentStateObject private var dataManager: DataManager

  init() {
    _dataManager = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }
  }

  var body: some View {
    Group {
      if auth.isLoggedIn {
        TabView(selection: $nav.selectedTab) {
          NavigationStack(path: nav.currentStackBinding) {
            MainView()
              .navigationDestination(for: Navigation.Destination.self) { destination in
                destinationView(for: destination)
              }
          }
          .tag(TabItem.home)

          NavigationStack(path: nav.currentStackBinding) {
            Contacts()
              .navigationDestination(for: Navigation.Destination.self) { destination in
                destinationView(for: destination)
              }
          }
          .tag(TabItem.contacts)

          NavigationStack(path: nav.currentStackBinding) {
            Settings()
              .navigationDestination(for: Navigation.Destination.self) { destination in
                destinationView(for: destination)
              }
          }
          .tag(TabItem.settings)
        }
        .overlay(alignment: .bottom) {
          if nav.isTabBarVisible {
            CustomTabBar(selectedTab: $nav.selectedTab)
          }
        }
        .sheet(item: $nav.activeSheet) { destination in
          sheetContent(for: destination)
        }
      } else {
        OnboardingView()
      }
    }
    .environmentObject(onboardingNav)
    .environmentObject(nav)
    .environmentObject(api)
    .environmentObject(userData)
    .environmentObject(dataManager)

  }

  @ViewBuilder
  func destinationView(for destination: Navigation.Destination) -> some View {
    switch destination {
    case .chat(let peer):
      ChatView(peer: peer)
    case .space(let id):
      SpaceView(spaceId: id)
    case .settings:
      Settings()
    case .contacts:
      Contacts()
    case .createSpace, .createDM, .createThread:
      EmptyView()  // These are handled by sheets
    case .main:
      MainView()
    }
  }

  @ViewBuilder
  func sheetContent(for destination: Navigation.Destination) -> some View {
    switch destination {
    case .createSpace:
      CreateSpace(showSheet: .constant(true))
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    case .createDM:
      CreateDm(showSheet: .constant(true))
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    case .createThread(let spaceId):
      CreateThread(showSheet: .constant(true), spaceId: spaceId)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    default:
      EmptyView()
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
}
