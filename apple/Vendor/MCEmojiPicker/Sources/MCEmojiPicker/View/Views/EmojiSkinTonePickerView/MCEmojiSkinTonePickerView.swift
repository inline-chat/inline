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

protocol MCEmojiSkinTonePickerViewDelegate: AnyObject {
    func didSelectEmojiTone(_ emojiToneIndex: Int?)
    func feedbackImpactOccurred()
}

final class MCEmojiSkinTonePickerView: UIView {
    
    // MARK: - Constants
    
    private enum Constants {
        static let topInset = 8.0
        static let horizontalAmountInset = 24.0
        static let stackViewSpacing = 4.0
        static let separatorInset = 12.0
        static let separatorWidth = 0.3
        static let separatorColor: UIColor = UIColor(
            light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.2),
            dark: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.2)
        )
    }
    
    // MARK: - Private Properties
    
    private lazy var backgroundView = MCEmojiSkinTonePickerBackgroundView(
        frame: bounds,
        senderFrame: sender.convert(sender.bounds, to: self)
    )
    private lazy var emojiLabels: [UIView] = {
        var arrangedSubviews = contentStackView.arrangedSubviews
        arrangedSubviews.remove(at: 1)
        return arrangedSubviews
    }()
    
    private var emoji: MCEmoji?
    private var selectedSkinTone: Int?
    
    private var contentStackView = UIStackView()
    
    private var sender: UIView
    private var sourceView: UIView
    private var emojiPickerFrame: CGRect
    
    private weak var delegate: MCEmojiSkinTonePickerViewDelegate?
    
    // MARK: - Initializers
    
    init(
        delegate: MCEmojiSkinTonePickerViewDelegate,
        emoji: MCEmoji?,
        sender: UIView,
        sourceView: UIView,
        emojiPickerFrame: CGRect
    ) {
        self.delegate = delegate
        self.emoji = emoji
        self.sender = sender
        self.sourceView = sourceView
        self.emojiPickerFrame = emojiPickerFrame
        super.init(frame: .zero)
        setupLayout()
        setupBackground()
        setupContent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Life Cycle
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        updateCurrentSelectedSkinToneIndex(with: touches, state: .began)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        updateCurrentSelectedSkinToneIndex(with: touches, state: .changed)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        delegate?.didSelectEmojiTone(selectedSkinTone)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        delegate?.didSelectEmojiTone(selectedSkinTone)
    }
    
    // MARK: - Private Methods
    
    private func updateCurrentSelectedSkinToneIndex(
        with touches: Set<UITouch>,
        state: UIGestureRecognizer.State
    ) {
        guard
            let location = touches.first?.location(in: contentStackView),
            let newSelectedIndex = emojiLabels.firstIndex(where: {
                return $0.frame.contains(
                    .init(
                        x: location.x,
                        y: $0.frame.midY
                    )
                )
            }),
            !(state == .began && !contentStackView.frame.contains(location)),
            selectedSkinTone != newSelectedIndex
        else { return }
        selectedSkinTone = newSelectedIndex
        if state != .began {
            delegate?.feedbackImpactOccurred()
        }
        for (index, emojiLabel) in emojiLabels.enumerated() {
            let isCurrentLabel = index == newSelectedIndex
            emojiLabel.backgroundColor = isCurrentLabel ? .systemBlue : .clear
        }
    }
    
    private func setupLayout() {
        let sourceRect = sender.convert(sender.bounds, to: sourceView)
        let targetViewSize = CGSize(
            width: sourceRect.width * 7.25,
            height: sourceRect.height * 2.65
        )
        
        frame = .init(
            x: sourceRect.midX - targetViewSize.width / 2,
            y: sourceRect.maxY - targetViewSize.height,
            width: targetViewSize.width,
            height: targetViewSize.height
        )

        if frame.minX < emojiPickerFrame.minX {
            frame.origin.x = emojiPickerFrame.minX
        }

        if frame.maxX > emojiPickerFrame.maxX {
            frame.origin.x = emojiPickerFrame.maxX - targetViewSize.width
        }
    }
    
    private func setupBackground() {
        addSubview(backgroundView)
    }
    
    private func setupContent() {
        let itemHeight = sender.convert(sender.bounds, to: sourceView).size.height
        let separatorSpacing = Constants.separatorInset * 2 + Constants.separatorWidth
        let itemsSpacing = Constants.stackViewSpacing * Double(MCEmojiSkinTone.allCases.count - 2)
        let allSpacings = separatorSpacing + itemsSpacing + Constants.horizontalAmountInset
        let itemWidth = round((backgroundView.contentFrame.width - allSpacings) / Double(MCEmojiSkinTone.allCases.count))
        let stackViewWidth = (Constants.stackViewSpacing * 4) + (itemWidth * Double(MCEmojiSkinTone.allCases.count)) + separatorSpacing
        
        var arrangedSubviews: [UIView] = MCEmojiSkinTone.allCases.map({
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: itemWidth).isActive = true
            label.heightAnchor.constraint(equalToConstant: itemHeight).isActive = true
            label.clipsToBounds = true
            label.layer.cornerRadius = itemHeight * 0.12
            label.font = UIFont.systemFont(ofSize: 29.fit(isOnlyToIncrease: false))
            var emojiKey = emoji?.emojiKeys ?? []
            if let skinToneKey = $0.skinKey {
                emojiKey.insert(skinToneKey, at: 1)
            }
            if emoji?.skinTone == $0 {
                label.backgroundColor = .systemBlue
            }
            label.text = emojiKey.emoji()
            label.textAlignment = .center
            return label
        })
        let separatorView: UIView = {
            let view = UIView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Constants.separatorWidth).isActive = true
            view.heightAnchor.constraint(equalToConstant: itemHeight - Constants.topInset).isActive = true
            view.backgroundColor = Constants.separatorColor
            return view
        }()
        arrangedSubviews.insert(separatorView, at: 1)
        
        contentStackView = UIStackView(arrangedSubviews: arrangedSubviews)
        contentStackView.alignment = .center
        contentStackView.spacing = Constants.stackViewSpacing
        contentStackView.frame = .init(
            x: (backgroundView.bounds.size.width - stackViewWidth) / 2,
            y: Constants.topInset,
            width: stackViewWidth,
            height: itemHeight
        )
        contentStackView.setCustomSpacing(Constants.separatorInset, after: separatorView)
        contentStackView.setCustomSpacing(Constants.separatorInset, after: arrangedSubviews[0])
        addSubview(contentStackView)
    }
}
