// The MIT License (MIT)
//
// Copyright © 2023 Ivan Izyumkin
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

import SwiftUI

@available(iOS 13, *)
extension View {
    /// The method adds a macOS style emoji picker.
    ///
    /// - Parameters:
    ///     - isPresented: Observed value which is responsible for the state of the picker.
    ///     - selectedEmoji: Observed value which is updated by the selected emoji.
    ///     - arrowDirection: The direction of the arrow for EmojiPicker.
    ///     - customHeight: Custom height for EmojiPicker.
    ///     - horizontalInset: Inset from the sourceView border.
    ///     - isDismissAfterChoosing: A boolean value that determines whether the screen will be hidden after the emoji is selected.
    ///     - selectedEmojiCategoryTintColor: Color for the selected emoji category.
    ///     - feedBackGeneratorStyle: Feedback generator style. To turn off, set `nil` to this parameter.
    @ViewBuilder public func emojiPicker(
        isPresented: Binding<Bool>,
        selectedEmoji: Binding<String>,
        arrowDirection: MCPickerArrowDirection? = nil,
        customHeight: CGFloat? = nil,
        horizontalInset: CGFloat? = nil,
        isDismissAfterChoosing: Bool? = nil,
        selectedEmojiCategoryTintColor: UIColor? = nil,
        feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle? = nil
    ) -> some View {
        self.overlay(
            MCEmojiPickerRepresentableController(
                isPresented: isPresented,
                selectedEmoji: selectedEmoji,
                arrowDirection: arrowDirection,
                customHeight: customHeight,
                horizontalInset: horizontalInset,
                isDismissAfterChoosing: isDismissAfterChoosing,
                selectedEmojiCategoryTintColor: selectedEmojiCategoryTintColor,
                feedBackGeneratorStyle: feedBackGeneratorStyle
            )
                .allowsHitTesting(false)
        )
    }
}
