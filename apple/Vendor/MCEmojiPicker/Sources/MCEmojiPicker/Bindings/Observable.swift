// The MIT License (MIT)
//
// Copyright © 2022 Ivan Izyumkin
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

/// Simple implementation of the observer pattern.
final class Observable<T> {
    
    // MARK: - Public Properties
    
    public typealias Listener = (T) -> Void
    
    /// Holds the current value of the observable.
    ///
    /// The `didSet` block ensures that the `Listener` closure is called whenever the value changes.
    public var value: T {
        didSet {
            listeners.forEach { $0(value) }
        }
    }
    
    // MARK: - Private Properties
    
    /// Holds a closure that will be called whenever the value changes.
    private var listeners = [Listener]()
    
    // MARK: - Initializers
    
    init(value: T) {
        self.value = value
    }
    
    // MARK: - Public Methods
    
    /// Allows you to set the `Listener` closure.
    public func bind(_ listener: @escaping Listener) {
        self.listeners.append(listener)
    }
}
