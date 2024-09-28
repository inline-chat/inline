import Foundation
import SwiftUI

class Navigation: ObservableObject {
    enum Destination {
        case welcome
        case email
    }
    
    @Published var path = NavigationPath()
    
    func push(_ destination: Destination) {
        path.append(destination)
    }
}
