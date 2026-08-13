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

final class MCEmojiSectionHeader: UICollectionReusableView {
    
    // MARK: - Constants
    
    private enum Constants {
        static let backgroundColor = UIColor.popoverBackgroundColor
        
        static let headerLabelColor = UIColor.systemGray
        static let headerLabelFont = UIFont.systemFont(ofSize: 14.fit(), weight: .regular)
        static let headerLabelInsets = UIEdgeInsets(top: 0, left: 7, bottom: -4, right: -16)
    }
    
    // MARK: - Private Properties
    
    private let headerLabel: UILabel = {
        let label: UILabel = UILabel()
        label.textColor = Constants.headerLabelColor
        label.font = Constants.headerLabelFont
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    // MARK: - Initializers
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupBackgroundColor()
        setupHeaderLabelLayout()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Public Methods
    
    public func configure(with categoryName: String) {
        headerLabel.text = categoryName
    }
    
    // MARK: - Private Methods
    
    private func setupBackgroundColor() {
        backgroundColor = Constants.backgroundColor
    }
    
    private func setupHeaderLabelLayout() {
        addSubview(headerLabel)
        
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Constants.headerLabelInsets.left
            ),
            headerLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: Constants.headerLabelInsets.right
            ),
            headerLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: Constants.headerLabelInsets.bottom
            )
        ])
    }
}
