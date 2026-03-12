import SwiftUI

public struct Welcome: View {
  public init() {}

  public var body: some View {
    VStack(){
      Text("Welcome to Inline!")
        .font(.largeTitle)
      
      if #available(iOS 26.0, macOS 26.0, *) {
        Button("Continue"){}
          .buttonStyle(.glassProminent)
          
      } else {
        Button("Continue"){}
        .buttonStyle(.borderedProminent)
      
      }
    }
    
  }
}

#Preview("Welcome") {
  Welcome()
}
