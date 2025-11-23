import InlineKit
import InlineUI
import SwiftUI
import UIKit

struct MainView: View {
  @EnvironmentObject private var homeViewModel: HomeViewModel
  @EnvironmentObject private var spaceSelection: SpaceSelectionViewModel

  var body: some View {
    Group {
      if let selectedSpace = spaceSelection.selectedSpace(in: homeViewModel.spaces) {
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
    .onChange(of: homeViewModel.spaces) { spaces in
      spaceSelection.pruneSelectionIfNeeded(spaces: spaces)
    }
  }
}
