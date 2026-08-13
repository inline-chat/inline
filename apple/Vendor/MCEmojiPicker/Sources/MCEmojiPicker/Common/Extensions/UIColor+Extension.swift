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

extension UIColor {
    /// Background color for `MCEmojiPickerView`.
    ///
    /// This is a standard color from UIKit - `.systemGroupedBackground`.
    static let popoverBackgroundColor = UIColor(
        light:  UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0),
        dark: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
    )
    /// Background color for `MCEmojiSkinTonePickerBackgroundView` and `MCEmojiPreviewView`.
    ///
    /// The colors were taken from similar iOS elements.
    static let previewAndSkinToneBackgroundViewColor = UIColor(
        light: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        dark: UIColor(red: 0.45, green: 0.45, blue: 0.46, alpha: 1.0)
    )
}

extension UIColor {
    /// Adds support for dark and light interface style modes.
    convenience init(light: UIColor, dark: UIColor) {
        if #available(iOS 13.0, *) {
            self.init(dynamicProvider: { trait in
                trait.userInterfaceStyle == .dark ? dark : light
            })
        } else {
            self.init(cgColor: light.cgColor)
        }
    }
}
