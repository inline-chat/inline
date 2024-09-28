//
//  ContentView.swift
//  InlineMac
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import SwiftUI

enum Page: Hashable {
    case onboarding
    case spaceView
}

class Nav: ObservableObject {
    @Published var currentPage: Page = .onboarding
    
    func navigate(to page: Page) {
        currentPage = page
    }
}

struct MainWindowContent: View {
    @StateObject var nav: Nav = .init()

    @ViewBuilder var activePage: some View {
        switch nav.currentPage {
            case .onboarding:
                OnboardingRoot()
            case .spaceView:
                SpaceView()
        }
    }

    var body: some View {
        activePage
            .frame(minWidth: 0,
                   idealWidth: 500,
                   maxWidth: .infinity,
                   minHeight: 0,
                   idealHeight: 300,
                   maxHeight: .infinity)
            .environmentObject(nav)
    }
}

#Preview {
    MainWindowContent()
}
