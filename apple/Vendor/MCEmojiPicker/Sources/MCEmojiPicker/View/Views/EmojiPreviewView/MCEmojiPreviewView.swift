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

final class MCEmojiPreviewView: UIView {
    
    // MARK: - Private Properties
    
    private let emojiLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 30.fit())
        label.textAlignment = .center
        return label
    }()
    
    private lazy var backgroundView = MCEmojiPreviewBackgroundView(
        frame: bounds,
        senderFrame: sender.convert(sender.bounds, to: self)
    )
    
    private var sender: UIView
    private var sourceView: UIView
    
    // MARK: - Initializers
    
    init(
        emoji: MCEmoji?,
        sender: UIView,
        sourceView: UIView
    ) {
        self.emojiLabel.text = emoji?.string
        self.sender = sender
        self.sourceView = sourceView
        super.init(frame: .zero)
        setupLayout()
        setupBackground()
        setupEmojiLabelLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Private Methods
    
    private func setupLayout() {
        let sourceRect = sender.convert(sender.bounds, to: sourceView)
        let targetViewSize = CGSize(
            width: sourceRect.height * 1.5,
            height: sourceRect.height * 2.65
        )
        
        frame = .init(
            x: sourceRect.midX - targetViewSize.width / 2,
            y: sourceRect.maxY - targetViewSize.height,
            width: targetViewSize.width,
            height: targetViewSize.height
        )
    }
    
    private func setupBackground() {
        addSubview(backgroundView)
    }
    
    private func setupEmojiLabelLayout() {
        emojiLabel.frame = backgroundView.contentFrame
        addSubview(emojiLabel)
    }
}
