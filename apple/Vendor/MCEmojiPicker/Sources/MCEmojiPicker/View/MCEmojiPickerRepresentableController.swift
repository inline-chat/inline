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

@available(iOS 13.0, *)
public struct MCEmojiPickerRepresentableController: UIViewControllerRepresentable {
    
    // MARK: - Public Properties
    
    /// Observed value which is responsible for the state of the picker.
    ///
    /// If the value of this property is `true`, the EmojiPicker will be presented.
    /// If the value of this property is `false`, the EmojiPicker will be hidden.
    @Binding var isPresented: Bool
    
    /// Observed value which is updated by the selected emoji.
    @Binding var selectedEmoji: String
    
    /// The direction of the arrow for EmojiPicker.
    ///
    /// The default value of this property is `.up`.
    public var arrowDirection: MCPickerArrowDirection?
    
    /// Custom height for EmojiPicker.
    /// But it will be limited by the distance from sourceView.origin.y to the upper or lower bound(depends on permittedArrowDirections).
    ///
    /// The default value of this property is `nil`.
    public var customHeight: CGFloat?
    
    /// Inset from the sourceView border.
    ///
    /// The default value of this property is `0`.
    public var horizontalInset: CGFloat?
    
    /// A boolean value that determines whether the screen will be hidden after the emoji is selected.
    ///
    /// If this property’s value is `true`, the EmojiPicker will be dismissed after the emoji is selected.
    /// If you want EmojiPicker not to dismissed after emoji selection, you must set this property to `false`.
    /// The default value of this property is `true`.
    public var isDismissAfterChoosing: Bool?
    
    /// Color for the selected emoji category.
    ///
    /// The default value of this property is `.systemBlue`.
    public var selectedEmojiCategoryTintColor: UIColor?
    
    /// Feedback generator style. To turn off, set `nil` to this parameter.
    ///
    /// The default value of this property is `.light`.
    public var feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle?
    
    // MARK: - Initializers
    
    public init(
        isPresented: Binding<Bool>,
        selectedEmoji: Binding<String>,
        arrowDirection: MCPickerArrowDirection? = nil,
        customHeight: CGFloat? = nil,
        horizontalInset: CGFloat? = nil,
        isDismissAfterChoosing: Bool? = nil,
        selectedEmojiCategoryTintColor: UIColor? = nil,
        feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle? = nil
    ) {
        self._isPresented = isPresented
        self._selectedEmoji = selectedEmoji
        self.arrowDirection = arrowDirection
        self.customHeight = customHeight
        self.horizontalInset = horizontalInset
        self.isDismissAfterChoosing = isDismissAfterChoosing
        self.selectedEmojiCategoryTintColor = selectedEmojiCategoryTintColor
        self.feedBackGeneratorStyle = feedBackGeneratorStyle
    }
    
    // MARK: - Public Methods
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }
    
    public func updateUIViewController(_ representableController: UIViewController, context: Context) {
        guard !context.coordinator.isNewEmojiSet else {
            context.coordinator.isNewEmojiSet.toggle()
            return
        }
        switch isPresented {
        case true:
            guard representableController.presentedViewController == nil else { return }
            let emojiPicker = MCEmojiPickerViewController()
            emojiPicker.delegate = context.coordinator
            emojiPicker.sourceView = representableController.view
            if let arrowDirection { emojiPicker.arrowDirection = arrowDirection }
            if let customHeight { emojiPicker.customHeight = customHeight }
            if let horizontalInset { emojiPicker.horizontalInset = horizontalInset }
            if let isDismissAfterChoosing { emojiPicker.isDismissAfterChoosing = isDismissAfterChoosing }
            if let selectedEmojiCategoryTintColor {
                emojiPicker.selectedEmojiCategoryTintColor = selectedEmojiCategoryTintColor
            }
            if let feedBackGeneratorStyle { emojiPicker.feedBackGeneratorStyle = feedBackGeneratorStyle }
            context.coordinator.addPickerDismissingObserver()
            representableController.present(emojiPicker, animated: true)
        case false:
            if representableController.presentedViewController is MCEmojiPickerViewController && context.coordinator.isPresented {
                representableController.presentedViewController?.dismiss(animated: true)
            }
        }
        context.coordinator.isPresented = isPresented
    }
}

// MARK: - Coordinator

@available(iOS 13.0, *)
extension MCEmojiPickerRepresentableController {
    public class Coordinator: NSObject, MCEmojiPickerDelegate {
        
        public var isNewEmojiSet = false
        public var isPresented = false
        
        private var representableController: MCEmojiPickerRepresentableController
        
        init(_ representableController: MCEmojiPickerRepresentableController) {
            self.representableController = representableController
        }
        
        public func addPickerDismissingObserver() {
            NotificationCenter.default.addObserver(self, selector: #selector(pickerDismissingAction), name: .MCEmojiPickerDidDisappear, object: nil)
        }
        
        public func didGetEmoji(emoji: String) {
            isNewEmojiSet.toggle()
            representableController.selectedEmoji = emoji
        }
        
        @objc public func pickerDismissingAction() {
            NotificationCenter.default.removeObserver(self, name: .MCEmojiPickerDidDisappear, object: nil)
            representableController.isPresented = false
        }
    }
}
