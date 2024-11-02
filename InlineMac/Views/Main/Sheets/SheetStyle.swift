import SwiftUI


extension View {
    func inlineSheetStyle() -> some View {
        self
            .presentationCornerRadius(12)
            .presentationBackground(.thinMaterial)
            .presentationBackgroundInteraction(.enabled)
    }
        
}
