import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct MainView: View {
  @EnvironmentObject private var homeViewModel: HomeViewModel

  var body: some View {
    Group {
      if let selectedSpace = homeViewModel.selectedSpace {
        SpaceView(spaceId: selectedSpace.id)
      } else {
        HomeView()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      ToolbarItem(placement: .principal) {
        SpacePickerView()
      }
    }
  }
}
