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

public protocol MCEmojiPickerDelegate: AnyObject {
    func didGetEmoji(emoji: String)
}

public final class MCEmojiPickerViewController: UIViewController {
    
    // MARK: - Public Properties
    
    /// Delegate for selecting an emoji object.
    public weak var delegate: MCEmojiPickerDelegate?
    
    /// The direction of the arrow for EmojiPicker.
    ///
    /// The default value of this property is `.up`.
    public var arrowDirection: MCPickerArrowDirection = .up
    
    /// Custom height for EmojiPicker.
    /// But it will be limited by the distance from sourceView.origin.y to the upper or lower bound(depends on permittedArrowDirections).
    ///
    /// The default value of this property is `nil`.
    public var customHeight: CGFloat? = nil
    
    /// Inset from the sourceView border.
    ///
    /// The default value of this property is `0`.
    public var horizontalInset: CGFloat = 0
    
    /// A boolean value that determines whether the screen will be hidden after the emoji is selected.
    ///
    /// If this property’s value is `true`, the EmojiPicker will be dismissed after the emoji is selected.
    /// If you want EmojiPicker not to dismissed after emoji selection, you must set this property to `false`.
    /// The default value of this property is `true`.
    public var isDismissAfterChoosing: Bool = true
    
    /// Color for the selected emoji category.
    ///
    /// The default value of this property is `.systemBlue`.
    public var selectedEmojiCategoryTintColor: UIColor? {
        didSet {
            guard let selectedEmojiCategoryTintColor = selectedEmojiCategoryTintColor else { return }
            emojiPickerView.selectedEmojiCategoryTintColor = selectedEmojiCategoryTintColor
        }
    }
    
    /// The view containing the anchor rectangle for the popover.
    public var sourceView: UIView? {
        didSet {
            popoverPresentationController?.sourceView = sourceView
        }
    }
    
    /// Feedback generator style. To turn off, set `nil` to this parameter.
    ///
    /// The default value of this property is `.light`.
    public var feedBackGeneratorStyle: UIImpactFeedbackGenerator.FeedbackStyle? = .light {
        didSet {
            guard let feedBackGeneratorStyle = feedBackGeneratorStyle else {
                generator = nil
                return
            }
            generator = UIImpactFeedbackGenerator(style: feedBackGeneratorStyle)
        }
    }
    
    // MARK: - Private Properties
    
    private var generator: UIImpactFeedbackGenerator? = UIImpactFeedbackGenerator(style: .light)
    private var viewModel: MCEmojiPickerViewModelProtocol = MCEmojiPickerViewModel()
    private lazy var emojiPickerView: MCEmojiPickerView = {
        let categories = viewModel.emojiCategories.map { $0.type }
        return MCEmojiPickerView(categoryTypes: categories, delegate: self)
    }()
    
    // MARK: - Initializers
    
    public init() {
        super.init(nibName: nil, bundle: nil)
        setupPopoverPresentationStyle()
        setupDelegates()
        bindViewModel()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Life Cycle
    
    public override func loadView() {
        view = emojiPickerView
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        setupPreferredContentSize()
        setupArrowDirections()
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupHorizontalInset()
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.post(name: .MCEmojiPickerDidDisappear, object: nil)
    }
    
    // MARK: - Private Methods
    
    private func bindViewModel() {
        viewModel.selectedEmoji.bind { [unowned self] emoji in
            guard let emoji = emoji else { return }
            feedbackImpactOccurred()
            delegate?.didGetEmoji(emoji: emoji.string)
            if isDismissAfterChoosing {
                dismiss(animated: true, completion: nil)
            }
        }
        viewModel.selectedEmojiCategoryIndex.bind { [unowned self] categoryIndex in
            self.emojiPickerView.updateSelectedCategoryIcon(with: categoryIndex)
        }
    }
    
    private func setupDelegates() {
        presentationController?.delegate = self
    }
    
    private func setupPopoverPresentationStyle() {
        modalPresentationStyle = .popover
    }
    
    private func setupPreferredContentSize() {
        preferredContentSize = {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone:
                let sideInset: CGFloat = 19
                let screenWidth: CGFloat = UIScreen.main.nativeBounds.width / UIScreen.main.nativeScale
                let popoverWidth: CGFloat = screenWidth - (sideInset * 2)
                // The number 0.16 was taken based on the proportion of height to the width of the EmojiPicker on MacOS.
                let heightProportionToWidth: CGFloat = 1.16
                return CGSize(
                    width: popoverWidth,
                    height: customHeight ?? popoverWidth * heightProportionToWidth
                )
            default:
                return CGSize(width: 340, height: 380)
            }
        }()
    }
    
    private func setupArrowDirections() {
        popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection(
            rawValue: arrowDirection.rawValue
        )
    }
    
    private func setupHorizontalInset() {
        guard let sourceView = sourceView else { return }
        popoverPresentationController?.sourceRect = CGRect(
            x: 0,
            y: popoverPresentationController?.arrowDirection == .up ? horizontalInset : -horizontalInset,
            width: sourceView.frame.width,
            height: sourceView.frame.height
        )
    }
}

// MARK: - EmojiPickerViewDelegate

extension MCEmojiPickerViewController: MCEmojiPickerViewDelegate {
    func didChoiceEmojiCategory(at index: Int) {
        updateCurrentSelectedEmojiCategoryIndex(with: index)
    }
    
    func numberOfSections() -> Int {
        viewModel.numberOfSections()
    }
    
    func numberOfItems(in section: Int) -> Int {
        viewModel.numberOfItems(in: section)
    }
    
    func emoji(at indexPath: IndexPath) -> MCEmoji {
        viewModel.emoji(at: indexPath)
    }
    
    func sectionHeaderName(for section: Int) -> String {
        viewModel.sectionHeaderName(for: section)
    }
    
    func getCurrentSelectedEmojiCategoryIndex() -> Int {
        viewModel.selectedEmojiCategoryIndex.value
    }
    
    func updateCurrentSelectedEmojiCategoryIndex(with index: Int) {
        viewModel.selectedEmojiCategoryIndex.value = index
    }
    
    func getEmojiPickerFrame() -> CGRect {
        presentationController?.presentedView?.frame ?? view.frame
    }
    
    func updateEmojiSkinTone(_ skinToneRawValue: Int, in indexPath: IndexPath) {
        viewModel.selectedEmoji.value = viewModel.updateEmojiSkinTone(
            skinToneRawValue,
            in: indexPath
        )
    }
    
    func feedbackImpactOccurred() {
        generator?.impactOccurred()
    }
    
    func didChoiceEmoji(_ emoji: MCEmoji?) {
        viewModel.selectedEmoji.value = emoji
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension MCEmojiPickerViewController: UIAdaptivePresentationControllerDelegate {
    public func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
}
