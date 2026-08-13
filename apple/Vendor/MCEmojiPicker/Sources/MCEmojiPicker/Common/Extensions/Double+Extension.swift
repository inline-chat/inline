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

import UIKit

extension Double {
    /// Angle `270°` in radians.
    static let downAngle: CGFloat = 1.5 * Double.pi
    /// Angle `180°` in radians.
    static let leftAngle: CGFloat = Double.pi
    /// Angle `90°` in radians.
    static let upAngle: CGFloat = Double.pi / 2
    /// Angle `0°` in radians.
    static let rightAngle: CGFloat = 0.0
    
    /// Used to increase various sizes (fonts, heights and widths).
    /// - Parameter isOnlyToIncrease: Responsible for whether the value will decrease if the screen size is smaller than the default.
    func fit(isOnlyToIncrease: Bool = true) -> Double {
        let defaultScreenSize = CGSize(width: 375, height: 812)
        let currentScreenSize = UIScreen.main.bounds.size
        // Check the type of the current device, if it is not a phone, return the original value.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return self }
        var scale = 1.0
        if isOnlyToIncrease && currentScreenSize.height > defaultScreenSize.height || !isOnlyToIncrease {
            scale = currentScreenSize.height / defaultScreenSize.height
        }
        return self * scale
    }
}
