import SwiftUI

// First, create an enum to represent different focusable elements
enum ChatFocusField {
  case compose
  case search // For future use if you add search
  // Add other focusable elements as needed
}

final class ChatFocus: ObservableObject {
  @Published var focusedField: ChatFocusField?
  
  func focusCompose() {
    focusedField = .compose
  }
  
  func clearFocus() {
    focusedField = nil
  }
}


// Custom modifier to handle focus binding
struct FocusBindingModifier: ViewModifier {
    @FocusState private var focusState: ChatFocusField?
    @ObservedObject var viewModel: ChatFocus
    let field: ChatFocusField
    
    func body(content: Content) -> some View {
        content
            .focused($focusState, equals: field)
            .onChange(of: viewModel.focusedField) { newValue in
                focusState = newValue
            }
            .onChange(of: focusState) { newValue in
                viewModel.focusedField = newValue
            }
    }
}

// Extension to make it easier to use
extension View {
    func bindChatViewFocus(to viewModel: ChatFocus, field: ChatFocusField) -> some View {
        modifier(FocusBindingModifier(viewModel: viewModel, field: field))
    }
}

