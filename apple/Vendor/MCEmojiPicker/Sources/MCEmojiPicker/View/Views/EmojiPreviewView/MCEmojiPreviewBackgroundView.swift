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

/// The class where the background is drawn for `MCEmojiPreviewView`.
final class MCEmojiPreviewBackgroundView: UIView {
    
    // MARK: - Public Properties
    
    public var contentFrame: CGRect {
        return .init(
            origin: .init(
                x: 0,
                y: Constants.mainCornerRadius / 2
            ),
            size: topRectangleFrame.size
        )
    }
    
    // MARK: - Constants
    
    private enum Constants {
        static let mainCornerRadius = 10.0
        static let bottomCornerRadius = 6.0
        
        static let shadowRadius: Double = 2.5
        static let shadowOpacity: Float = 0.05
        static let shadowOffset: CGSize = .init(width: 0, height: 5)
        
        static let borderWidth = 0.1
    }
    
    // MARK: - Private Properties
    
    private var backgroundPath: CGPath? {
        didSet {
            setupShadow()
            setupBorders()
        }
    }
    
    private var senderFrame: CGRect
    private var topRectangleFrame: CGRect = .zero
    private var bottomRectangleFrame: CGRect = .zero
    
    // MARK: - Initializers
    
    init(
        frame: CGRect,
        senderFrame: CGRect
    ) {
        self.senderFrame = senderFrame
        super.init(frame: frame)
        backgroundColor = .clear
        initFramesForRectangles()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Private Methods
    
    private func initFramesForRectangles() {
        bottomRectangleFrame = .init(
            x: senderFrame.origin.x,
            y: senderFrame.origin.y - (senderFrame.height * 1.25 - senderFrame.height),
            width: senderFrame.width,
            height: senderFrame.height * 1.25
        )
        topRectangleFrame = .init(
            origin: .zero,
            size: .init(
                width: frame.width,
                height: frame.height - (
                    bottomRectangleFrame.height
                )
            )
        )
    }
    
    private func setupShadow() {
        layer.shadowPath = backgroundPath
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = Constants.shadowRadius
        layer.shadowOpacity = Constants.shadowOpacity
        layer.shadowOffset = Constants.shadowOffset
    }
    
    private func setupBorders() {
        let borderLayer = CAShapeLayer()
        borderLayer.path = backgroundPath
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.gray.cgColor
        borderLayer.lineWidth = Constants.borderWidth
        borderLayer.frame = bounds
        layer.addSublayer(borderLayer)
    }
}

// MARK: - Drawing

extension MCEmojiPreviewBackgroundView {
    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawBackground()
    }
    
    private func drawBackground() {
        UIColor.previewAndSkinToneBackgroundViewColor.setFill()
        
        let path = UIBezierPath()
        path.addArc(
            withCenter: .init(
                x: bottomRectangleFrame.minX + Constants.bottomCornerRadius,
                y: bottomRectangleFrame.maxY - Constants.bottomCornerRadius
            ),
            radius: Constants.bottomCornerRadius,
            startAngle: Double.upAngle,
            endAngle: Double.leftAngle,
            clockwise: true
        )
        path.addLine(
            to: .init(
                x: bottomRectangleFrame.minX,
                y: bottomRectangleFrame.minY + Constants.mainCornerRadius * 2
            )
        )
        path.addCurve(
            to: .init(
                x: topRectangleFrame.minX,
                y: topRectangleFrame.maxY - Constants.mainCornerRadius
            ),
            controlPoint1: .init(
                x: bottomRectangleFrame.minX,
                y: bottomRectangleFrame.minY - Constants.mainCornerRadius / 2
            ),
            controlPoint2: .init(
                x: topRectangleFrame.minX,
                y: topRectangleFrame.maxY + Constants.mainCornerRadius / 2
            )
        )
        path.addArc(
            withCenter: .init(
                x: topRectangleFrame.minX + Constants.mainCornerRadius,
                y: topRectangleFrame.minY + Constants.mainCornerRadius
            ),
            radius: Constants.mainCornerRadius,
            startAngle: Double.leftAngle,
            endAngle: Double.downAngle,
            clockwise: true
        )
        path.addArc(
            withCenter: .init(
                x: topRectangleFrame.maxX - Constants.mainCornerRadius,
                y: topRectangleFrame.minY + Constants.mainCornerRadius
            ),
            radius: Constants.mainCornerRadius,
            startAngle: Double.downAngle,
            endAngle: Double.rightAngle,
            clockwise: true
        )
        path.addLine(
            to: .init(
                x: topRectangleFrame.maxX,
                y: topRectangleFrame.maxY - Constants.mainCornerRadius
            )
        )
        path.addCurve(
            to: .init(
                x: bottomRectangleFrame.maxX,
                y: bottomRectangleFrame.minY + Constants.mainCornerRadius * 2
            ),
            controlPoint1: .init(
                x: topRectangleFrame.maxX,
                y: topRectangleFrame.maxY + Constants.mainCornerRadius / 2
            ),
            controlPoint2: .init(
                x: bottomRectangleFrame.maxX,
                y: bottomRectangleFrame.minY - Constants.mainCornerRadius / 2
            )
        )
        path.addArc(
            withCenter: .init(
                x: bottomRectangleFrame.maxX - Constants.bottomCornerRadius,
                y: bottomRectangleFrame.maxY - Constants.bottomCornerRadius
            ),
            radius: Constants.bottomCornerRadius,
            startAngle: Double.rightAngle,
            endAngle: Double.upAngle,
            clockwise: true
        )
        path.close()
        path.fill()
        
        backgroundPath = path.cgPath
    }
}
