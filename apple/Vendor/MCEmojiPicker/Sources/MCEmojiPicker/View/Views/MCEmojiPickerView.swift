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

protocol MCEmojiPickerViewDelegate: AnyObject {
    /// Processes an event by category selection.
    ///
    /// - Parameter index: index of the selected category.
    func didChoiceEmojiCategory(at index: Int)
    func didChoiceEmoji(_ emoji: MCEmoji?)
    func numberOfSections() -> Int
    func numberOfItems(in section: Int) -> Int
    func emoji(at indexPath: IndexPath) -> MCEmoji
    func sectionHeaderName(for section: Int) -> String
    func getCurrentSelectedEmojiCategoryIndex() -> Int
    func updateCurrentSelectedEmojiCategoryIndex(with index: Int)
    func getEmojiPickerFrame() -> CGRect
    func updateEmojiSkinTone(_ skinToneRawValue: Int, in indexPath: IndexPath)
    func feedbackImpactOccurred()
}

final class MCEmojiPickerView: UIView {

    // MARK: - Public Properties

    public var selectedEmojiCategoryTintColor = Constants.defaultSelectedEmojiCategoryTintColor

    // MARK: - Constants

    private enum Constants {
        static let defaultSelectedEmojiCategoryTintColor = UIColor.systemBlue

        static let verticalScrollIndicatorTopInset = 8.0
        static let collectionViewContentInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        static let countOfEmojisInRow = 8.0
        static let collectionViewHeaderHeight = 40.0

        static let categoriesStackViewInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: -16)

        static let separatorHeight = 0.8
        static let separatorColor = UIColor(
            light: UIColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1.0),
            dark: UIColor(red: 0.22, green: 0.22, blue: 0.23, alpha: 1.0)
        )
    }

    // MARK: - Private Properties

    private let emojiCategoryTypes: [MCEmojiCategoryType]

    private let collectionView: UICollectionView = {
        let layout: UICollectionViewFlowLayout = UICollectionViewFlowLayout()
        layout.sectionHeadersPinToVisibleBounds = true
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.verticalScrollIndicatorInsets.top = Constants.verticalScrollIndicatorTopInset
        collectionView.contentInset = Constants.collectionViewContentInsets
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(
            MCEmojiCollectionViewCell.self,
            forCellWithReuseIdentifier: MCEmojiCollectionViewCell.reuseIdentifier
        )
        collectionView.register(
            MCEmojiSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: MCEmojiSectionHeader.reuseIdentifier
        )
        return collectionView
    }()

    private let categoriesStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.backgroundColor = .popoverBackgroundColor
        stackView.distribution = .fillEqually
        return stackView
    }()

    private var previewContainerView = UIView()
    private var categoryViews = [MCTouchableEmojiCategoryView]()
    private var isViewHierarchyConfigured = false

    /// Height for categoriesStackView.
    private lazy var categoriesStackViewHeight: CGFloat = {
        // The number 0.13 was taken based on the proportion of this element to the width of the EmojiPicker on MacOS.
        return bounds.width * 0.13
    }()

    private weak var delegate: MCEmojiPickerViewDelegate?

    // MARK: - Initializers

    init(categoryTypes: [MCEmojiCategoryType] = MCEmojiCategoryType.allCases, delegate: MCEmojiPickerViewDelegate) {
        self.delegate = delegate
        self.emojiCategoryTypes = categoryTypes
        super.init(frame: .zero)
        setupBackgroundColor()
        setupDelegates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Life Cycle

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        // Upstream 1.2.3, 1.2.5, and main configure this hierarchy on every
        // draw, duplicating category controls and constraints after redraws.
        guard !isViewHierarchyConfigured else { return }
        isViewHierarchyConfigured = true
        setupCategoryViews()
        setupCollectionViewLayout()
        setupCollectionViewBottomInsets()
        setupCategoriesControlLayout()
    }

    // MARK: - Public Methods

    /// Passes the index of the selected category to all categoryViews to update the state.
    ///
    /// - Parameter categoryIndex: Selected category index.
    public func updateSelectedCategoryIcon(with categoryIndex: Int) {
        categoryViews.forEach({
            $0.updateCategoryViewState(selectedCategoryIndex: categoryIndex)
        })
    }

    // MARK: - Private Methods

    private func setupBackgroundColor() {
        backgroundColor = .popoverBackgroundColor
    }

    private func setupDelegates() {
        collectionView.delegate = self
        collectionView.dataSource = self
    }

    private func setupCollectionViewBottomInsets() {
        collectionView.contentInset.bottom = categoriesStackViewHeight
        collectionView.verticalScrollIndicatorInsets.bottom = categoriesStackViewHeight
    }

    private func setupCollectionViewLayout() {
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor, constant: safeAreaInsets.top),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -safeAreaInsets.bottom)
        ])
    }

    private func setupCategoriesControlLayout() {
        let separatorView = UIView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = Constants.separatorColor

        addSubview(categoriesStackView)
        addSubview(separatorView)

        NSLayoutConstraint.activate([
            categoriesStackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Constants.categoriesStackViewInsets.left
            ),
            categoriesStackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: Constants.categoriesStackViewInsets.right
            ),
            categoriesStackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -safeAreaInsets.bottom
            ),
            categoriesStackView.heightAnchor.constraint(
                equalToConstant: categoriesStackViewHeight
            ),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.topAnchor.constraint(equalTo: categoriesStackView.topAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: Constants.separatorHeight)
        ])
    }

    private func setupCategoryViews() {
        for categoryIndex in 0...emojiCategoryTypes.count - 1 {
            let categoryView = MCTouchableEmojiCategoryView(
                delegate: self,
                categoryIndex: categoryIndex,
                categoryType: emojiCategoryTypes[categoryIndex],
                selectedEmojiCategoryTintColor: selectedEmojiCategoryTintColor
            )
            // Installing selected state for first category.
            categoryView.updateCategoryViewState(selectedCategoryIndex: .zero)
            categoryViews.append(categoryView)
            categoriesStackView.addArrangedSubview(categoryView)
        }
    }

    private func toggleCollectionScrollAbility(isEnabled: Bool) {
        collectionView.isScrollEnabled = isEnabled
    }

    /// Scroll collectionView to header for selected category.
    ///
    /// - Parameter section: Selected category index.
    private func scrollToHeader(for section: Int) {
        guard let cellFrame = collectionView.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame,
              let headerFrame = collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: .zero, section: section)
              )?.frame
        else { return }
        collectionView.setContentOffset(
            CGPoint(
                x: -collectionView.contentInset.left,
                y: cellFrame.minY - headerFrame.height
            ),
            animated: false
        )
    }
}

// MARK: - UICollectionViewDataSource

extension MCEmojiPickerView: UICollectionViewDataSource {
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        return delegate?.numberOfSections() ?? .zero
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        return delegate?.numberOfItems(in: section) ?? .zero
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MCEmojiCollectionViewCell.reuseIdentifier,
                for: indexPath
              ) as? MCEmojiCollectionViewCell
        else { return UICollectionViewCell() }
        cell.configure(
            emoji: delegate?.emoji(at: indexPath),
            delegate: self
        )
        return cell
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let sectionHeader = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: MCEmojiSectionHeader.reuseIdentifier,
                for: indexPath
              ) as? MCEmojiSectionHeader
        else { return UICollectionReusableView() }
        sectionHeader.configure(
            with: delegate?.sectionHeaderName(
                for: indexPath.section
            ) ?? ""
        )
        return sectionHeader
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension MCEmojiPickerView: UICollectionViewDelegateFlowLayout {
    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        return CGSize(
            width: collectionView.frame.width,
            height: Constants.collectionViewHeaderHeight
        )
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let sideInsets = collectionView.contentInset.right + collectionView.contentInset.left
        let contentSize = collectionView.bounds.width - sideInsets
        return CGSize(
            width: contentSize / Constants.countOfEmojisInRow,
            height: contentSize / Constants.countOfEmojisInRow
        )
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        return .zero
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
        return .zero
    }
}

// MARK: - UIScrollViewDelegate

extension MCEmojiPickerView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Updating the selected category during scrolling
        let indexPathsForVisibleHeaders = collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ).sorted(by: { $0.section < $1.section })
        if let selectedEmojiCategoryIndex = indexPathsForVisibleHeaders.first?.section,
           delegate?.getCurrentSelectedEmojiCategoryIndex() != selectedEmojiCategoryIndex {
            delegate?.updateCurrentSelectedEmojiCategoryIndex(with: selectedEmojiCategoryIndex)
        }
    }
}

// MARK: - MCEmojiCollectionViewCellDelegate

extension MCEmojiPickerView: MCEmojiCollectionViewCellDelegate {
    func preview(_ emoji: MCEmoji?, in cell: MCEmojiCollectionViewCell) {
        guard let sourceView = window else { return }
        toggleCollectionScrollAbility(isEnabled: false)

        previewContainerView.removeFromSuperview()
        previewContainerView = MCEmojiPreviewView(
            emoji: emoji,
            sender: cell.emojiLabel,
            sourceView: sourceView
        )

        sourceView.addSubview(previewContainerView)
    }

    func choiceSkinTone(_ emoji: MCEmoji?, in cell: MCEmojiCollectionViewCell) {
        guard let sourceView = window else { return }
        toggleCollectionScrollAbility(isEnabled: false)
        delegate?.feedbackImpactOccurred()

        previewContainerView.removeFromSuperview()
        previewContainerView = MCEmojiSkinTonePickerContainerView(
            delegate: self,
            cell: cell,
            emoji: emoji,
            frame: sourceView.frame,
            sourceView: sourceView,
            emojiPickerFrame: delegate?.getEmojiPickerFrame() ?? .zero
        )

        sourceView.addSubview(previewContainerView)
    }

    func didSelect(_ emoji: MCEmoji?, in cell: MCEmojiCollectionViewCell) {
        if previewContainerView is MCEmojiPreviewView {
            toggleCollectionScrollAbility(isEnabled: true)
            previewContainerView.removeFromSuperview()
        }
        delegate?.didChoiceEmoji(emoji)
    }
}

// MARK: - EmojiCategoryViewDelegate

extension MCEmojiPickerView: MCEmojiCategoryViewDelegate {
    func didChoiceCategory(at index: Int) {
        scrollToHeader(for: index)
        delegate?.feedbackImpactOccurred()
        delegate?.didChoiceEmojiCategory(at: index)
    }
}

// MARK: - MCEmojiSkinTonePickerDelegate

extension MCEmojiPickerView: MCEmojiSkinTonePickerDelegate {
    func updateSkinTone(
        _ skinToneRawValue: Int,
        in cell: MCEmojiCollectionViewCell
    ) {
        guard let indexPath = collectionView.indexPath(for: cell) else { return }
        delegate?.updateEmojiSkinTone(skinToneRawValue, in: indexPath)
        UIView.performWithoutAnimation {
            collectionView.reloadData()
        }
    }

    func feedbackImpactOccurred() {
        delegate?.feedbackImpactOccurred()
    }

    func didEmojiSkinTonePickerDismissed() {
        toggleCollectionScrollAbility(isEnabled: true)
    }
}
