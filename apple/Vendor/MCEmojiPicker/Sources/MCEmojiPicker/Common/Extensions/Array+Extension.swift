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

extension Array where Element == Int {
    /// Converts hex values into emoji.
    ///
    /// This example shows that one emoji can consist of either one hex value or several.
    /// ```
    /// print([0x1F600].emoji()) // "😀"
    /// print([0x1F635, 0x200D, 0x1F4AB].emoji()) // "😵‍💫"
    /// ```
    /// But if you put hex values not related to one emoji in one array. You will get a string of several emojis.
    /// ```
    /// print([0x1F600, 0x1F635, 0x200D, 0x1F4AB].emoji()) // "😀😵‍💫"
    /// ```
    func emoji() -> String {
        return self
            // Converting hex value into a 32-bit integer representation of emoji in the Unicode table.
            .map({ UnicodeScalar($0) })
            // Removing the optional.
            .compactMap({ $0 })
            // Converting a 32-bit integer to a character for correct representation.
            .map({ String($0) })
            // Combine all the received values to get the final emoji.
            .joined()
    }
}
