import Foundation

extension Array {
    func compact<T>() -> [T] where Element == Optional<T> {
        compactMap { $0 }
    }
}



