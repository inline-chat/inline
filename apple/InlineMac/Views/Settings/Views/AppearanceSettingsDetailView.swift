import SwiftUI

struct AppearanceSettingsDetailView: View {
  @ObservedObject private var settings = AppSettings.shared

  var body: some View {
    Form {
   
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  AppearanceSettingsDetailView()
}
