// import SwiftUI
//
// struct FormStateData {
//    var loading: Bool
//    var error: String?
//    var succeeded: Bool?
// }
//
//// A helper for easier state management for simple forms
// class FormStateObject: ObservableObject {
//    @Published private(set) var state: FormStateData
//
//    // Streamlined access
//    var isLoading: Bool { state.loading }
//    var hasError: String? { state.error }
//    var hasSucceeded: Bool? { state.succeeded }
//
//    init() {
//        self.state = FormStateData(loading: false, error: nil, succeeded: nil)
//    }
//
//    func reset() {
//        state = FormStateData(loading: false, error: nil, succeeded: nil)
//    }
//
//    func startLoading() {
//        state = FormStateData(loading: true, error: nil, succeeded: nil)
//    }
//
//    func failed(error: String?) {
//        state = FormStateData(loading: false, error: error, succeeded: false)
//    }
//
//    func succeeded() {
//        state = FormStateData(loading: false, error: nil, succeeded: true)
//    }
// }
//
// @propertyWrapper
// struct FormState: DynamicProperty {
//    @StateObject private var state = FormStateObject()
//
//    var wrappedValue: FormStateObject {
//        state
//    }
// }
