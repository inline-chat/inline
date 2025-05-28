import SwiftUI

struct SpinnerView: View {
  var body: some View {
    VStack {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle())
        .scaleEffect(0.7)
        .padding()
    }
  }
}

#Preview {
  SpinnerView()
}
