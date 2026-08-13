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

/// States for `MCEmojiCategoryIconView`.
enum MCEmojiCategoryIconViewState {
    case standard
    case highlighted
    case selected
}

/// Responsible for rendering the icon for the target emoji category in the desired color.
final class MCEmojiCategoryIconView: UIView {
    
    // MARK: - Private Properties
    
    /// Target icon type.
    private var type: MCEmojiCategoryType
    /// Current tint color for the icon.
    private var currentIconTintColor: UIColor = .systemGray
    /// Selected tint color for the icon.
    private var selectedIconTintColor: UIColor
    /// Current icon state.
    private var state: MCEmojiCategoryIconViewState = .standard
    
    // MARK: - Initializers
    
    init(
        type: MCEmojiCategoryType,
        selectedIconTintColor: UIColor
    ) {
        self.type = type
        self.selectedIconTintColor = selectedIconTintColor
        super.init(frame: .zero)
        setupBackground()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Public Methods
    
    /// New centered rect based on bounds width to prevent stretching of the icon.
    ///
    /// - Parameter state: Target icon state. Based on this state, the target color will be selected.
    public func updateIconTintColor(for state: MCEmojiCategoryIconViewState) {
        guard self.state != state else { return }
        self.state = state
        switch state {
        case .standard:
            currentIconTintColor = .systemGray
        case .highlighted:
            currentIconTintColor = adjust(color: currentIconTintColor)
        case .selected:
            currentIconTintColor = selectedIconTintColor
        }
        setNeedsDisplay()
    }
    
    // MARK: - Private Methods
    
    /// Increases brightness or decreases saturation.
    private func adjust(color: UIColor, by percentage: CGFloat = 40.0) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            switch brightness < 1.0 {
            case true:
                let newB: CGFloat = max(min(brightness + (percentage / 100.0) * brightness, 1.0), 0.0)
                return UIColor(hue: hue, saturation: saturation, brightness: newB, alpha: alpha)
            case false:
                let newS: CGFloat = min(max(saturation - (percentage / 100.0) * saturation, 0.0), 1.0)
                return UIColor(hue: hue, saturation: newS, brightness: brightness, alpha: alpha)
            }
        }
        return color
    }
    
    private func setupBackground() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }
}

// MARK: - Drawing

extension MCEmojiCategoryIconView {
    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        // New centered rect based on bounds width to prevent stretching of the icon.
        let rect = CGRect(
            origin: CGPoint(
                x: 0,
                y: (rect.height - rect.width) / 2
            ),
            size: CGSize(
                width: rect.width,
                height: rect.width
            )
        )
        switch type {
        case .frequentlyUsed:
            CategoryIconsDrawKit.drawFrequentlyUsedCategory(frame: rect, tintColor: currentIconTintColor)
        case .people:
            CategoryIconsDrawKit.drawPeopleCategory(frame: rect, tintColor: currentIconTintColor)
        case .nature:
            CategoryIconsDrawKit.drawNatureCategory(frame: rect, tintColor: currentIconTintColor)
        case .foodAndDrink:
            CategoryIconsDrawKit.drawFoodAndDrinkCategory(frame: rect, tintColor: currentIconTintColor)
        case .activity:
            CategoryIconsDrawKit.drawActivityCategory(frame: rect, tintColor: currentIconTintColor)
        case .travelAndPlaces:
            CategoryIconsDrawKit.drawTravelAndPlacesCategory(frame: rect, tintColor: currentIconTintColor)
        case .objects:
            CategoryIconsDrawKit.drawObjectsCategory(frame: rect, tintColor: currentIconTintColor)
        case .symbols:
            CategoryIconsDrawKit.drawSymbolsCategory(frame: rect, tintColor: currentIconTintColor)
        case .flags:
            CategoryIconsDrawKit.drawFlagsCategory(frame: rect, tintColor: currentIconTintColor)
        }
    }
    
    /// Responsible for rendering icons for emoji categories.
    private class CategoryIconsDrawKit: NSObject {

        public enum ResizingBehavior: Int {
            /// The content is proportionally resized to fit into the target rectangle.
            case aspectFit
            /// The content is proportionally resized to completely fill the target rectangle.
            case aspectFill
            /// The content is stretched to match the entire target rectangle.
            case stretch
            /// The content is centered in the target rectangle, but it is NOT resized.
            case center

            public func apply(rect: CGRect, target: CGRect) -> CGRect {
                if rect == target || target == CGRect.zero {
                    return rect
                }

                var scales = CGSize.zero
                scales.width = abs(target.width / rect.width)
                scales.height = abs(target.height / rect.height)

                switch self {
                    case .aspectFit:
                        scales.width = min(scales.width, scales.height)
                        scales.height = scales.width
                    case .aspectFill:
                        scales.width = max(scales.width, scales.height)
                        scales.height = scales.width
                    case .stretch:
                        break
                    case .center:
                        scales.width = 1
                        scales.height = 1
                }

                var result = rect.standardized
                result.size.width *= scales.width
                result.size.height *= scales.height
                result.origin.x = target.minX + (target.width - result.width) / 2
                result.origin.y = target.minY + (target.height - result.height) / 2
                return result
            }
        }

        // MARK: - People Category
        
        public class func drawFrequentlyUsedCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            let shape = UIBezierPath()
            shape.move(to: CGPoint(x: 89.74, y: 215.05))
            shape.addLine(to: CGPoint(x: 195.75, y: 215.05))
            shape.addCurve(to: CGPoint(x: 206.58, y: 204.28), controlPoint1: CGPoint(x: 201.8, y: 215.05), controlPoint2: CGPoint(x: 206.58, y: 210.46))
            shape.addLine(to: CGPoint(x: 206.58, y: 67.37))
            shape.addCurve(to: CGPoint(x: 195.75, y: 56.86), controlPoint1: CGPoint(x: 206.58, y: 61.39), controlPoint2: CGPoint(x: 201.8, y: 56.86))
            shape.addCurve(to: CGPoint(x: 185.24, y: 67.37), controlPoint1: CGPoint(x: 189.89, y: 56.86), controlPoint2: CGPoint(x: 185.24, y: 61.39))
            shape.addLine(to: CGPoint(x: 185.24, y: 193.77))
            shape.addLine(to: CGPoint(x: 89.74, y: 193.77))
            shape.addCurve(to: CGPoint(x: 79.04, y: 204.28), controlPoint1: CGPoint(x: 83.57, y: 193.77), controlPoint2: CGPoint(x: 79.04, y: 198.36))
            shape.addCurve(to: CGPoint(x: 89.74, y: 215.05), controlPoint1: CGPoint(x: 79.04, y: 210.46), controlPoint2: CGPoint(x: 83.57, y: 215.05))
            shape.close()
            shape.move(to: CGPoint(x: 195.89, y: 391.78))
            shape.addCurve(to: CGPoint(x: 391.84, y: 195.89), controlPoint1: CGPoint(x: 303.3, y: 391.78), controlPoint2: CGPoint(x: 391.84, y: 303.1))
            shape.addCurve(to: CGPoint(x: 195.75, y: 0), controlPoint1: CGPoint(x: 391.84, y: 88.54), controlPoint2: CGPoint(x: 303.16, y: 0))
            shape.addCurve(to: CGPoint(x: 0, y: 195.89), controlPoint1: CGPoint(x: 88.54, y: 0), controlPoint2: CGPoint(x: 0, y: 88.54))
            shape.addCurve(to: CGPoint(x: 195.89, y: 391.78), controlPoint1: CGPoint(x: 0, y: 303.1), controlPoint2: CGPoint(x: 88.67, y: 391.78))
            shape.close()
            shape.move(to: CGPoint(x: 195.89, y: 366.45))
            shape.addCurve(to: CGPoint(x: 25.47, y: 195.89), controlPoint1: CGPoint(x: 101.4, y: 366.45), controlPoint2: CGPoint(x: 25.47, y: 290.38))
            shape.addCurve(to: CGPoint(x: 195.75, y: 25.27), controlPoint1: CGPoint(x: 25.47, y: 101.4), controlPoint2: CGPoint(x: 101.27, y: 25.27))
            shape.addCurve(to: CGPoint(x: 366.51, y: 195.89), controlPoint1: CGPoint(x: 290.24, y: 25.27), controlPoint2: CGPoint(x: 366.51, y: 101.4))
            shape.addCurve(to: CGPoint(x: 195.89, y: 366.45), controlPoint1: CGPoint(x: 366.51, y: 290.38), controlPoint2: CGPoint(x: 290.38, y: 366.45))
            shape.close()
            tintColor.setFill()
            shape.fill()
            
            context.restoreGState()
        }

        public class func drawPeopleCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            let ovalPath = UIBezierPath(ovalIn: CGRect(x: 14, y: 14, width: 372, height: 372))
            tintColor.setStroke()
            ovalPath.lineWidth = 20
            ovalPath.stroke()
            
            let oval2Path = UIBezierPath(ovalIn: CGRect(x: 235, y: 123, width: 46, height: 57))
            tintColor.setFill()
            oval2Path.fill()
            
            let oval3Path = UIBezierPath(ovalIn: CGRect(x: 120, y: 123, width: 46, height: 57))
            tintColor.setFill()
            oval3Path.fill()
            
            let bezierPath = UIBezierPath()
            bezierPath.move(to: CGPoint(x: 199.5, y: 235.47))
            bezierPath.addCurve(to: CGPoint(x: 334, y: 235.47), controlPoint1: CGPoint(x: 273.79, y: 235.47), controlPoint2: CGPoint(x: 334, y: 198.42))
            bezierPath.addCurve(to: CGPoint(x: 199.5, y: 349), controlPoint1: CGPoint(x: 334, y: 272.52), controlPoint2: CGPoint(x: 282.27, y: 349))
            bezierPath.addCurve(to: CGPoint(x: 65, y: 235.47), controlPoint1: CGPoint(x: 116.41, y: 349), controlPoint2: CGPoint(x: 65, y: 272.52))
            bezierPath.addCurve(to: CGPoint(x: 199.5, y: 235.47), controlPoint1: CGPoint(x: 65, y: 198.42), controlPoint2: CGPoint(x: 125.21, y: 235.47))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 96.13, y: 239.21))
            bezierPath.addCurve(to: CGPoint(x: 96, y: 239.93), controlPoint1: CGPoint(x: 96.05, y: 239.44), controlPoint2: CGPoint(x: 96, y: 239.68))
            bezierPath.addLine(to: CGPoint(x: 96, y: 256.39))
            bezierPath.addCurve(to: CGPoint(x: 96.82, y: 258), controlPoint1: CGPoint(x: 96, y: 257.03), controlPoint2: CGPoint(x: 96.3, y: 257.63))
            bezierPath.addCurve(to: CGPoint(x: 199, y: 288), controlPoint1: CGPoint(x: 124.15, y: 278), controlPoint2: CGPoint(x: 158.21, y: 288))
            bezierPath.addCurve(to: CGPoint(x: 301.18, y: 258), controlPoint1: CGPoint(x: 239.79, y: 288), controlPoint2: CGPoint(x: 273.85, y: 278))
            bezierPath.addCurve(to: CGPoint(x: 302, y: 256.39), controlPoint1: CGPoint(x: 301.7, y: 257.63), controlPoint2: CGPoint(x: 302, y: 257.03))
            bezierPath.addLine(to: CGPoint(x: 302, y: 239.93))
            bezierPath.addCurve(to: CGPoint(x: 300, y: 237.93), controlPoint1: CGPoint(x: 302, y: 238.82), controlPoint2: CGPoint(x: 301.1, y: 237.93))
            bezierPath.addCurve(to: CGPoint(x: 299.28, y: 238.06), controlPoint1: CGPoint(x: 299.75, y: 237.93), controlPoint2: CGPoint(x: 299.51, y: 237.97))
            bezierPath.addCurve(to: CGPoint(x: 199, y: 257.4), controlPoint1: CGPoint(x: 265.85, y: 250.95), controlPoint2: CGPoint(x: 232.43, y: 257.4))
            bezierPath.addCurve(to: CGPoint(x: 98.72, y: 238.06), controlPoint1: CGPoint(x: 165.57, y: 257.4), controlPoint2: CGPoint(x: 132.15, y: 250.95))
            bezierPath.addCurve(to: CGPoint(x: 96.13, y: 239.21), controlPoint1: CGPoint(x: 97.69, y: 237.67), controlPoint2: CGPoint(x: 96.53, y: 238.18))
            bezierPath.close()
            bezierPath.usesEvenOddFillRule = true
            tintColor.setFill()
            bezierPath.fill()
            
            context.restoreGState()
        }
        
        // MARK: - Nature Category

         public class func drawNatureCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            let bezierPath = UIBezierPath()
            bezierPath.move(to: CGPoint(x: 252.54, y: 57.99))
            bezierPath.addCurve(to: CGPoint(x: 337.17, y: 51.32), controlPoint1: CGPoint(x: 252.54, y: 57.99), controlPoint2: CGPoint(x: 298.47, y: 9.87))
            bezierPath.addCurve(to: CGPoint(x: 327.12, y: 145.87), controlPoint1: CGPoint(x: 374.14, y: 90.93), controlPoint2: CGPoint(x: 327.12, y: 145.87))
            tintColor.setStroke()
            bezierPath.lineWidth = 20
            bezierPath.miterLimit = 20
            bezierPath.stroke()
            
            let bezier2Path = UIBezierPath()
            bezier2Path.move(to: CGPoint(x: 153, y: 60.12))
            bezier2Path.addCurve(to: CGPoint(x: 64.31, y: 51.11), controlPoint1: CGPoint(x: 153, y: 60.12), controlPoint2: CGPoint(x: 102.8, y: 10.2))
            bezier2Path.addCurve(to: CGPoint(x: 73.25, y: 141), controlPoint1: CGPoint(x: 27.53, y: 90.2), controlPoint2: CGPoint(x: 73.25, y: 141))
            tintColor.setStroke()
            bezier2Path.lineWidth = 20
            bezier2Path.miterLimit = 20
            bezier2Path.stroke()
            
            let ovalPath = UIBezierPath(ovalIn: CGRect(x: 251, y: 172, width: 42, height: 57))
            tintColor.setFill()
            ovalPath.fill()
            
            let bezier3Path = UIBezierPath()
            bezier3Path.move(to: CGPoint(x: 210.56, y: 292.46))
            bezier3Path.addCurve(to: CGPoint(x: 201, y: 295), controlPoint1: CGPoint(x: 207.17, y: 294.04), controlPoint2: CGPoint(x: 203.88, y: 295))
            bezier3Path.addCurve(to: CGPoint(x: 191.57, y: 292.53), controlPoint1: CGPoint(x: 198.15, y: 295), controlPoint2: CGPoint(x: 194.91, y: 294.07))
            bezier3Path.addLine(to: CGPoint(x: 181.18, y: 286))
            bezier3Path.addCurve(to: CGPoint(x: 164, y: 260.82), controlPoint1: CGPoint(x: 171.87, y: 278.65), controlPoint2: CGPoint(x: 164, y: 268.29))
            bezier3Path.addCurve(to: CGPoint(x: 177.88, y: 248), controlPoint1: CGPoint(x: 164, y: 248), controlPoint2: CGPoint(x: 177.88, y: 248))
            bezier3Path.addLine(to: CGPoint(x: 201, y: 248))
            bezier3Path.addLine(to: CGPoint(x: 224.12, y: 248))
            bezier3Path.addCurve(to: CGPoint(x: 238, y: 260.82), controlPoint1: CGPoint(x: 224.12, y: 248), controlPoint2: CGPoint(x: 238, y: 248))
            bezier3Path.addCurve(to: CGPoint(x: 220.95, y: 285.9), controlPoint1: CGPoint(x: 238, y: 268.26), controlPoint2: CGPoint(x: 230.2, y: 278.54))
            bezier3Path.addLine(to: CGPoint(x: 210.56, y: 292.46))
            bezier3Path.close()
            bezier3Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier3Path.fill()
            
            let bezier4Path = UIBezierPath()
            bezier4Path.move(to: CGPoint(x: 209.15, y: 319.52))
            bezier4Path.addCurve(to: CGPoint(x: 212.7, y: 316.69), controlPoint1: CGPoint(x: 210.04, y: 319.52), controlPoint2: CGPoint(x: 212.44, y: 319.52))
            bezier4Path.addLine(to: CGPoint(x: 223, y: 317.3))
            bezier4Path.addCurve(to: CGPoint(x: 209.15, y: 330), controlPoint1: CGPoint(x: 222.75, y: 322.4), controlPoint2: CGPoint(x: 218.87, y: 330))
            bezier4Path.addCurve(to: CGPoint(x: 199.58, y: 326.25), controlPoint1: CGPoint(x: 204.21, y: 330), controlPoint2: CGPoint(x: 201.22, y: 327.95))
            bezier4Path.addCurve(to: CGPoint(x: 196, y: 317.05), controlPoint1: CGPoint(x: 195.97, y: 322.49), controlPoint2: CGPoint(x: 195.99, y: 317.48))
            bezier4Path.addLine(to: CGPoint(x: 196, y: 288.66))
            bezier4Path.addCurve(to: CGPoint(x: 206.32, y: 282), controlPoint1: CGPoint(x: 204.58, y: 283.07), controlPoint2: CGPoint(x: 204.58, y: 283.07))
            bezier4Path.addLine(to: CGPoint(x: 206.32, y: 317.18))
            bezier4Path.addCurve(to: CGPoint(x: 206.97, y: 318.93), controlPoint1: CGPoint(x: 206.32, y: 317.2), controlPoint2: CGPoint(x: 206.41, y: 318.36))
            bezier4Path.addCurve(to: CGPoint(x: 209.15, y: 319.52), controlPoint1: CGPoint(x: 207.43, y: 319.42), controlPoint2: CGPoint(x: 208.41, y: 319.52))
            bezier4Path.close()
            bezier4Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier4Path.fill()
            
            let bezier5Path = UIBezierPath()
            bezier5Path.move(to: CGPoint(x: 209.15, y: 319.52))
            bezier5Path.addCurve(to: CGPoint(x: 212.7, y: 316.69), controlPoint1: CGPoint(x: 210.04, y: 319.52), controlPoint2: CGPoint(x: 212.44, y: 319.52))
            bezier5Path.addLine(to: CGPoint(x: 223, y: 317.3))
            bezier5Path.addCurve(to: CGPoint(x: 209.15, y: 330), controlPoint1: CGPoint(x: 222.75, y: 322.4), controlPoint2: CGPoint(x: 218.87, y: 330))
            bezier5Path.addCurve(to: CGPoint(x: 199.58, y: 326.25), controlPoint1: CGPoint(x: 204.21, y: 330), controlPoint2: CGPoint(x: 201.22, y: 327.95))
            bezier5Path.addCurve(to: CGPoint(x: 196, y: 317.05), controlPoint1: CGPoint(x: 195.97, y: 322.49), controlPoint2: CGPoint(x: 195.99, y: 317.48))
            bezier5Path.addLine(to: CGPoint(x: 196, y: 288.66))
            bezier5Path.addCurve(to: CGPoint(x: 206.32, y: 282), controlPoint1: CGPoint(x: 204.58, y: 283.07), controlPoint2: CGPoint(x: 204.58, y: 283.07))
            bezier5Path.addLine(to: CGPoint(x: 206.32, y: 317.18))
            bezier5Path.addCurve(to: CGPoint(x: 206.97, y: 318.93), controlPoint1: CGPoint(x: 206.32, y: 317.2), controlPoint2: CGPoint(x: 206.41, y: 318.36))
            bezier5Path.addCurve(to: CGPoint(x: 209.15, y: 319.52), controlPoint1: CGPoint(x: 207.43, y: 319.42), controlPoint2: CGPoint(x: 208.41, y: 319.52))
            bezier5Path.close()
            tintColor.setStroke()
            bezier5Path.lineWidth = 1
            bezier5Path.miterLimit = 1
            bezier5Path.stroke()
            
            let bezier6Path = UIBezierPath()
            bezier6Path.move(to: CGPoint(x: 192.85, y: 319.52))
            bezier6Path.addCurve(to: CGPoint(x: 189.3, y: 316.69), controlPoint1: CGPoint(x: 191.96, y: 319.52), controlPoint2: CGPoint(x: 189.56, y: 319.52))
            bezier6Path.addLine(to: CGPoint(x: 179, y: 317.3))
            bezier6Path.addCurve(to: CGPoint(x: 192.85, y: 330), controlPoint1: CGPoint(x: 179.25, y: 322.4), controlPoint2: CGPoint(x: 183.13, y: 330))
            bezier6Path.addCurve(to: CGPoint(x: 202.42, y: 326.25), controlPoint1: CGPoint(x: 197.79, y: 330), controlPoint2: CGPoint(x: 200.78, y: 327.95))
            bezier6Path.addCurve(to: CGPoint(x: 206, y: 317.05), controlPoint1: CGPoint(x: 206.03, y: 322.49), controlPoint2: CGPoint(x: 206.01, y: 317.48))
            bezier6Path.addLine(to: CGPoint(x: 206, y: 288.66))
            bezier6Path.addCurve(to: CGPoint(x: 195.68, y: 282), controlPoint1: CGPoint(x: 197.42, y: 283.07), controlPoint2: CGPoint(x: 197.42, y: 283.07))
            bezier6Path.addLine(to: CGPoint(x: 195.68, y: 317.18))
            bezier6Path.addCurve(to: CGPoint(x: 195.03, y: 318.93), controlPoint1: CGPoint(x: 195.68, y: 317.2), controlPoint2: CGPoint(x: 195.59, y: 318.36))
            bezier6Path.addCurve(to: CGPoint(x: 192.85, y: 319.52), controlPoint1: CGPoint(x: 194.57, y: 319.42), controlPoint2: CGPoint(x: 193.59, y: 319.52))
            bezier6Path.close()
            bezier6Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier6Path.fill()
            
            let bezier7Path = UIBezierPath()
            bezier7Path.move(to: CGPoint(x: 192.85, y: 319.52))
            bezier7Path.addCurve(to: CGPoint(x: 189.3, y: 316.69), controlPoint1: CGPoint(x: 191.96, y: 319.52), controlPoint2: CGPoint(x: 189.56, y: 319.52))
            bezier7Path.addLine(to: CGPoint(x: 179, y: 317.3))
            bezier7Path.addCurve(to: CGPoint(x: 192.85, y: 330), controlPoint1: CGPoint(x: 179.25, y: 322.4), controlPoint2: CGPoint(x: 183.13, y: 330))
            bezier7Path.addCurve(to: CGPoint(x: 202.42, y: 326.25), controlPoint1: CGPoint(x: 197.79, y: 330), controlPoint2: CGPoint(x: 200.78, y: 327.95))
            bezier7Path.addCurve(to: CGPoint(x: 206, y: 317.05), controlPoint1: CGPoint(x: 206.03, y: 322.49), controlPoint2: CGPoint(x: 206.01, y: 317.48))
            bezier7Path.addLine(to: CGPoint(x: 206, y: 288.66))
            bezier7Path.addCurve(to: CGPoint(x: 195.68, y: 282), controlPoint1: CGPoint(x: 197.42, y: 283.07), controlPoint2: CGPoint(x: 197.42, y: 283.07))
            bezier7Path.addLine(to: CGPoint(x: 195.68, y: 317.18))
            bezier7Path.addCurve(to: CGPoint(x: 195.03, y: 318.93), controlPoint1: CGPoint(x: 195.68, y: 317.2), controlPoint2: CGPoint(x: 195.59, y: 318.36))
            bezier7Path.addCurve(to: CGPoint(x: 192.85, y: 319.52), controlPoint1: CGPoint(x: 194.57, y: 319.42), controlPoint2: CGPoint(x: 193.59, y: 319.52))
            bezier7Path.close()
            tintColor.setStroke()
            bezier7Path.lineWidth = 1
            bezier7Path.miterLimit = 1
            bezier7Path.stroke()
            
            let oval2Path = UIBezierPath(ovalIn: CGRect(x: 108, y: 172, width: 42, height: 57))
            tintColor.setFill()
            oval2Path.fill()
            
            let bezier8Path = UIBezierPath()
            bezier8Path.move(to: CGPoint(x: 204.73, y: 43))
            bezier8Path.addCurve(to: CGPoint(x: 65.18, y: 154.91), controlPoint1: CGPoint(x: 99.8, y: 43), controlPoint2: CGPoint(x: 65.18, y: 154.91))
            bezier8Path.addCurve(to: CGPoint(x: 23.2, y: 262.68), controlPoint1: CGPoint(x: 65.18, y: 154.91), controlPoint2: CGPoint(x: 5.77, y: 200.68))
            bezier8Path.addCurve(to: CGPoint(x: 111.35, y: 337.27), controlPoint1: CGPoint(x: 44.19, y: 337.27), controlPoint2: CGPoint(x: 111.35, y: 337.27))
            bezier8Path.addLine(to: CGPoint(x: 131.72, y: 337.27))
            bezier8Path.addLine(to: CGPoint(x: 139.92, y: 337.27))
            bezier8Path.addCurve(to: CGPoint(x: 200.13, y: 366), controlPoint1: CGPoint(x: 155.98, y: 358.82), controlPoint2: CGPoint(x: 184.07, y: 366))
            bezier8Path.addCurve(to: CGPoint(x: 259.85, y: 337.27), controlPoint1: CGPoint(x: 216.19, y: 366), controlPoint2: CGPoint(x: 243.8, y: 358.82))
            bezier8Path.addLine(to: CGPoint(x: 269.08, y: 337.27))
            bezier8Path.addLine(to: CGPoint(x: 288.65, y: 337.27))
            bezier8Path.addCurve(to: CGPoint(x: 376.8, y: 262.68), controlPoint1: CGPoint(x: 288.65, y: 337.27), controlPoint2: CGPoint(x: 355.81, y: 337.27))
            bezier8Path.addCurve(to: CGPoint(x: 334.82, y: 154.91), controlPoint1: CGPoint(x: 394.23, y: 200.68), controlPoint2: CGPoint(x: 334.82, y: 154.91))
            bezier8Path.addCurve(to: CGPoint(x: 204.73, y: 43), controlPoint1: CGPoint(x: 334.82, y: 154.91), controlPoint2: CGPoint(x: 309.65, y: 43))
            bezier8Path.close()
            tintColor.setStroke()
            bezier8Path.lineWidth = 20
            bezier8Path.miterLimit = 20
            bezier8Path.stroke()
            
            context.restoreGState()
        }
        
        // MARK: - Food And Drink Category

         public class func drawFoodAndDrinkCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            let bezierPath = UIBezierPath()
            bezierPath.move(to: CGPoint(x: 162.72, y: 99.23))
            bezierPath.addLine(to: CGPoint(x: 171.73, y: 49.8))
            bezierPath.addLine(to: CGPoint(x: 232.3, y: 70.5))
            bezierPath.addLine(to: CGPoint(x: 239, y: 50.92))
            bezierPath.addLine(to: CGPoint(x: 168.47, y: 26.82))
            bezierPath.addCurve(to: CGPoint(x: 168.41, y: 26.8), controlPoint1: CGPoint(x: 168.45, y: 26.81), controlPoint2: CGPoint(x: 168.43, y: 26.81))
            bezierPath.addLine(to: CGPoint(x: 167.12, y: 26.36))
            bezierPath.addLine(to: CGPoint(x: 167.11, y: 26.39))
            bezierPath.addCurve(to: CGPoint(x: 164.42, y: 26), controlPoint1: CGPoint(x: 166.25, y: 26.16), controlPoint2: CGPoint(x: 165.36, y: 26))
            bezierPath.addCurve(to: CGPoint(x: 154.42, y: 33.82), controlPoint1: CGPoint(x: 159.59, y: 26), controlPoint2: CGPoint(x: 155.55, y: 29.32))
            bezierPath.addLine(to: CGPoint(x: 154.38, y: 33.8))
            bezierPath.addLine(to: CGPoint(x: 141.82, y: 99.23))
            bezierPath.addLine(to: CGPoint(x: 162.72, y: 99.23))
            bezierPath.close()
            bezierPath.usesEvenOddFillRule = true
            tintColor.setFill()
            bezierPath.fill()
            
            let bezier2Path = UIBezierPath()
            bezier2Path.move(to: CGPoint(x: 7, y: 99))
            bezier2Path.addLine(to: CGPoint(x: 190, y: 99))
            bezier2Path.addLine(to: CGPoint(x: 188.05, y: 119))
            bezier2Path.addLine(to: CGPoint(x: 9.03, y: 119))
            bezier2Path.addLine(to: CGPoint(x: 7, y: 99))
            bezier2Path.close()
            bezier2Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier2Path.fill()
            
            let bezier3Path = UIBezierPath()
            bezier3Path.move(to: CGPoint(x: 7, y: 99))
            bezier3Path.addLine(to: CGPoint(x: 27, y: 99))
            bezier3Path.addLine(to: CGPoint(x: 54.48, y: 374))
            bezier3Path.addLine(to: CGPoint(x: 34.48, y: 374))
            bezier3Path.addLine(to: CGPoint(x: 7, y: 99))
            bezier3Path.close()
            bezier3Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier3Path.fill()
            
            let bezier4Path = UIBezierPath()
            bezier4Path.move(to: CGPoint(x: 81.84, y: 304))
            bezier4Path.addCurve(to: CGPoint(x: 73.04, y: 341.05), controlPoint1: CGPoint(x: 77.06, y: 316.6), controlPoint2: CGPoint(x: 72.91, y: 334.07))
            bezier4Path.addCurve(to: CGPoint(x: 223.55, y: 373.92), controlPoint1: CGPoint(x: 73.75, y: 377.24), controlPoint2: CGPoint(x: 140.42, y: 373.92))
            bezier4Path.addCurve(to: CGPoint(x: 376.96, y: 341.05), controlPoint1: CGPoint(x: 306.68, y: 373.92), controlPoint2: CGPoint(x: 376.96, y: 375))
            bezier4Path.addCurve(to: CGPoint(x: 369.55, y: 304), controlPoint1: CGPoint(x: 376.96, y: 334.21), controlPoint2: CGPoint(x: 373.74, y: 316.84))
            bezier4Path.addLine(to: CGPoint(x: 81.84, y: 304))
            bezier4Path.close()
            tintColor.setStroke()
            bezier4Path.lineWidth = 20
            bezier4Path.miterLimit = 20
            bezier4Path.stroke()
            
            let bezier5Path = UIBezierPath()
            bezier5Path.move(to: CGPoint(x: 371.87, y: 256))
            bezier5Path.addLine(to: CGPoint(x: 354.12, y: 259.94))
            bezier5Path.addLine(to: CGPoint(x: 220.85, y: 294.71))
            bezier5Path.addLine(to: CGPoint(x: 217.15, y: 295.53))
            bezier5Path.addLine(to: CGPoint(x: 213.46, y: 294.66))
            bezier5Path.addLine(to: CGPoint(x: 76.01, y: 259.88))
            bezier5Path.addLine(to: CGPoint(x: 67.14, y: 257.79))
            bezier5Path.addCurve(to: CGPoint(x: 58, y: 282.87), controlPoint1: CGPoint(x: 59.99, y: 265.29), controlPoint2: CGPoint(x: 58, y: 275.21))
            bezier5Path.addCurve(to: CGPoint(x: 76.47, y: 308), controlPoint1: CGPoint(x: 58, y: 292.74), controlPoint2: CGPoint(x: 63.95, y: 300.09))
            bezier5Path.addLine(to: CGPoint(x: 375.41, y: 308))
            bezier5Path.addCurve(to: CGPoint(x: 392, y: 280.66), controlPoint1: CGPoint(x: 388.58, y: 299.7), controlPoint2: CGPoint(x: 392, y: 290.83))
            bezier5Path.addCurve(to: CGPoint(x: 381.54, y: 256.02), controlPoint1: CGPoint(x: 392, y: 272.11), controlPoint2: CGPoint(x: 391.21, y: 263.33))
            bezier5Path.addCurve(to: CGPoint(x: 371.87, y: 256), controlPoint1: CGPoint(x: 381.2, y: 256.01), controlPoint2: CGPoint(x: 377.7, y: 256.01))
            bezier5Path.close()
            bezier5Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier5Path.fill()
            
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            
            let clipPath = UIBezierPath()
            clipPath.move(to: CGPoint(x: 373.74, y: 246))
            clipPath.addLine(to: CGPoint(x: 76.26, y: 246))
            clipPath.addLine(to: CGPoint(x: 216.78, y: 293))
            clipPath.addLine(to: CGPoint(x: 373.74, y: 246))
            clipPath.close()
            clipPath.move(to: CGPoint(x: 60.24, y: 230))
            clipPath.addLine(to: CGPoint(x: 389.76, y: 230))
            clipPath.addLine(to: CGPoint(x: 389.76, y: 309))
            clipPath.addLine(to: CGPoint(x: 60.24, y: 309))
            clipPath.addLine(to: CGPoint(x: 60.24, y: 230))
            clipPath.close()
            clipPath.usesEvenOddFillRule = true
            clipPath.addClip()
            
            let bezier6Path = UIBezierPath()
            bezier6Path.move(to: CGPoint(x: 373.74, y: 246))
            bezier6Path.addLine(to: CGPoint(x: 76.26, y: 246))
            bezier6Path.addLine(to: CGPoint(x: 216.78, y: 293))
            bezier6Path.addLine(to: CGPoint(x: 373.74, y: 246))
            bezier6Path.close()
            tintColor.setStroke()
            bezier6Path.lineWidth = 30
            bezier6Path.miterLimit = 30
            bezier6Path.lineJoinStyle = .round
            bezier6Path.stroke()

            context.endTransparencyLayer()
            context.restoreGState()
            
            let bezier8Path = UIBezierPath()
            bezier8Path.move(to: CGPoint(x: 69.25, y: 237))
            bezier8Path.addLine(to: CGPoint(x: 378.66, y: 237))
            bezier8Path.addCurve(to: CGPoint(x: 382.33, y: 226.8), controlPoint1: CGPoint(x: 380.81, y: 234.35), controlPoint2: CGPoint(x: 382.33, y: 232.07))
            bezier8Path.addCurve(to: CGPoint(x: 225.61, y: 154), controlPoint1: CGPoint(x: 382.33, y: 178.81), controlPoint2: CGPoint(x: 311.99, y: 154))
            bezier8Path.addCurve(to: CGPoint(x: 67.67, y: 226.8), controlPoint1: CGPoint(x: 139.24, y: 154), controlPoint2: CGPoint(x: 67.67, y: 178.81))
            bezier8Path.addCurve(to: CGPoint(x: 69.25, y: 237), controlPoint1: CGPoint(x: 67.67, y: 230.85), controlPoint2: CGPoint(x: 68.27, y: 234.07))
            bezier8Path.close()
            tintColor.setStroke()
            bezier8Path.lineWidth = 20
            bezier8Path.miterLimit = 20
            bezier8Path.stroke()
            
            let rectanglePath = UIBezierPath(rect: CGRect(x: 49, y: 354, width: 41, height: 20))
            tintColor.setFill()
            rectanglePath.fill()
            
            let bezier9Path = UIBezierPath()
            bezier9Path.move(to: CGPoint(x: 170, y: 99))
            bezier9Path.addLine(to: CGPoint(x: 190, y: 99))
            bezier9Path.addLine(to: CGPoint(x: 184.4, y: 156))
            bezier9Path.addLine(to: CGPoint(x: 164.4, y: 156))
            bezier9Path.addLine(to: CGPoint(x: 170, y: 99))
            bezier9Path.close()
            bezier9Path.usesEvenOddFillRule = true
            tintColor.setFill()
            bezier9Path.fill()
            
            context.restoreGState()
        }
            
        // MARK: - Activity Category

         public class func drawActivityCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
             
             let ovalPath = UIBezierPath(ovalIn: CGRect(x: 12, y: 12, width: 376, height: 376))
             tintColor.setStroke()
             ovalPath.lineWidth = 20
             ovalPath.stroke()
             
             let bezierPath = UIBezierPath()
             bezierPath.move(to: CGPoint(x: 271.2, y: 292.04))
             bezierPath.addLine(to: CGPoint(x: 223.21, y: 278.64))
             bezierPath.addLine(to: CGPoint(x: 176.15, y: 303.11))
             bezierPath.addLine(to: CGPoint(x: 160.88, y: 292.96))
             bezierPath.addLine(to: CGPoint(x: 218.46, y: 262.95))
             bezierPath.addLine(to: CGPoint(x: 218.46, y: 206.41))
             bezierPath.addLine(to: CGPoint(x: 228.52, y: 186.19))
             bezierPath.addLine(to: CGPoint(x: 271.36, y: 160.45))
             bezierPath.addCurve(to: CGPoint(x: 271.36, y: 96.97), controlPoint1: CGPoint(x: 270.38, y: 112.38), controlPoint2: CGPoint(x: 270.38, y: 91.22))
             bezierPath.addLine(to: CGPoint(x: 290.26, y: 103.94))
             bezierPath.addCurve(to: CGPoint(x: 290.2, y: 154.07), controlPoint1: CGPoint(x: 290.01, y: 127.78), controlPoint2: CGPoint(x: 289.98, y: 144.49))
             bezierPath.addLine(to: CGPoint(x: 291.03, y: 153.66))
             bezierPath.addLine(to: CGPoint(x: 324.56, y: 206.82))
             bezierPath.addLine(to: CGPoint(x: 366.84, y: 197.49))
             bezierPath.addLine(to: CGPoint(x: 371.7, y: 172.12))
             bezierPath.addLine(to: CGPoint(x: 377.33, y: 172.12))
             bezierPath.addCurve(to: CGPoint(x: 377.25, y: 231.7), controlPoint1: CGPoint(x: 380.66, y: 192.11), controlPoint2: CGPoint(x: 380.63, y: 211.97))
             bezierPath.addLine(to: CGPoint(x: 366.55, y: 211.7))
             bezierPath.addLine(to: CGPoint(x: 332.9, y: 220.04))
             bezierPath.addLine(to: CGPoint(x: 288.61, y: 292.39))
             bezierPath.addLine(to: CGPoint(x: 287.01, y: 336.04))
             bezierPath.addLine(to: CGPoint(x: 313.26, y: 339.26))
             bezierPath.addCurve(to: CGPoint(x: 271.2, y: 366.02), controlPoint1: CGPoint(x: 299.74, y: 350.26), controlPoint2: CGPoint(x: 285.72, y: 359.18))
             bezierPath.addCurve(to: CGPoint(x: 229.32, y: 378.29), controlPoint1: CGPoint(x: 256.68, y: 372.86), controlPoint2: CGPoint(x: 242.72, y: 376.95))
             bezierPath.addLine(to: CGPoint(x: 229.34, y: 372.51))
             bezierPath.addLine(to: CGPoint(x: 176.28, y: 353.04))
             bezierPath.addLine(to: CGPoint(x: 176.15, y: 341.41))
             bezierPath.addLine(to: CGPoint(x: 237.51, y: 363.66))
             bezierPath.addLine(to: CGPoint(x: 270.66, y: 341.32))
             bezierPath.addCurve(to: CGPoint(x: 271.2, y: 292.04), controlPoint1: CGPoint(x: 271.02, y: 308.46), controlPoint2: CGPoint(x: 271.2, y: 292.04))
             bezierPath.close()
             bezierPath.usesEvenOddFillRule = true
             tintColor.setFill()
             bezierPath.fill()
             
             let bezier2Path = UIBezierPath()
             bezier2Path.move(to: CGPoint(x: 218.46, y: 206.41))
             bezier2Path.addLine(to: CGPoint(x: 155.31, y: 171.03))
             bezier2Path.addLine(to: CGPoint(x: 166.06, y: 153.14))
             bezier2Path.addLine(to: CGPoint(x: 228.52, y: 186.19))
             bezier2Path.addLine(to: CGPoint(x: 218.46, y: 206.41))
             bezier2Path.close()
             bezier2Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier2Path.fill()
             
             let bezier3Path = UIBezierPath()
             bezier3Path.move(to: CGPoint(x: 219.36, y: 52.44))
             bezier3Path.addLine(to: CGPoint(x: 219.36, y: 22.29))
             bezier3Path.addLine(to: CGPoint(x: 222.91, y: 20))
             bezier3Path.addCurve(to: CGPoint(x: 282.56, y: 37.15), controlPoint1: CGPoint(x: 243.58, y: 22.84), controlPoint2: CGPoint(x: 264.27, y: 27.8))
             bezier3Path.addCurve(to: CGPoint(x: 334.14, y: 77.17), controlPoint1: CGPoint(x: 301.64, y: 46.91), controlPoint2: CGPoint(x: 320.37, y: 62.64))
             bezier3Path.addLine(to: CGPoint(x: 334.14, y: 83.09))
             bezier3Path.addLine(to: CGPoint(x: 290.07, y: 104.06))
             bezier3Path.addLine(to: CGPoint(x: 271.11, y: 96.99))
             bezier3Path.addLine(to: CGPoint(x: 221.32, y: 65.69))
             bezier3Path.addLine(to: CGPoint(x: 219.36, y: 52.44))
             bezier3Path.close()
             bezier3Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier3Path.fill()
             
             let bezier4Path = UIBezierPath()
             bezier4Path.move(to: CGPoint(x: 161.74, y: 81.17))
             bezier4Path.addLine(to: CGPoint(x: 219.36, y: 51.18))
             bezier4Path.addLine(to: CGPoint(x: 221.76, y: 65.9))
             bezier4Path.addLine(to: CGPoint(x: 165.57, y: 96.97))
             bezier4Path.addLine(to: CGPoint(x: 161.74, y: 81.17))
             bezier4Path.close()
             bezier4Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier4Path.fill()
             
             let bezier5Path = UIBezierPath()
             bezier5Path.move(to: CGPoint(x: 92.54, y: 201.76))
             bezier5Path.addLine(to: CGPoint(x: 61.64, y: 153.48))
             bezier5Path.addLine(to: CGPoint(x: 20.79, y: 171.7))
             bezier5Path.addLine(to: CGPoint(x: 21.59, y: 167.08))
             bezier5Path.addCurve(to: CGPoint(x: 23.57, y: 157.03), controlPoint1: CGPoint(x: 22.16, y: 163.7), controlPoint2: CGPoint(x: 22.8, y: 160.34))
             bezier5Path.addLine(to: CGPoint(x: 23.85, y: 155.81))
             bezier5Path.addLine(to: CGPoint(x: 58.31, y: 140.41))
             bezier5Path.addLine(to: CGPoint(x: 92.49, y: 85.71))
             bezier5Path.addLine(to: CGPoint(x: 85.08, y: 63.23))
             bezier5Path.addCurve(to: CGPoint(x: 90.63, y: 58.42), controlPoint1: CGPoint(x: 85.08, y: 63.23), controlPoint2: CGPoint(x: 89.12, y: 59.56))
             bezier5Path.addCurve(to: CGPoint(x: 96.83, y: 54.32), controlPoint1: CGPoint(x: 92.14, y: 57.27), controlPoint2: CGPoint(x: 96.83, y: 54.32))
             bezier5Path.addLine(to: CGPoint(x: 107.11, y: 80.23))
             bezier5Path.addLine(to: CGPoint(x: 161.74, y: 81.17))
             bezier5Path.addLine(to: CGPoint(x: 165.57, y: 96.97))
             bezier5Path.addLine(to: CGPoint(x: 166.06, y: 153.14))
             bezier5Path.addLine(to: CGPoint(x: 155.31, y: 171.03))
             bezier5Path.addLine(to: CGPoint(x: 108.93, y: 201.29))
             bezier5Path.addLine(to: CGPoint(x: 92.54, y: 201.76))
             bezier5Path.close()
             bezier5Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier5Path.fill()
             
             let bezier6Path = UIBezierPath()
             bezier6Path.move(to: CGPoint(x: 92.54, y: 258.03))
             bezier6Path.addLine(to: CGPoint(x: 109.23, y: 264.27))
             bezier6Path.addLine(to: CGPoint(x: 108.93, y: 201.08))
             bezier6Path.addLine(to: CGPoint(x: 92.54, y: 201.76))
             bezier6Path.addLine(to: CGPoint(x: 92.54, y: 258.03))
             bezier6Path.close()
             bezier6Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier6Path.fill()
             
             let bezier7Path = UIBezierPath()
             bezier7Path.move(to: CGPoint(x: 176.28, y: 353.04))
             bezier7Path.addLine(to: CGPoint(x: 128.8, y: 355.44))
             bezier7Path.addLine(to: CGPoint(x: 128.45, y: 367.25))
             bezier7Path.addCurve(to: CGPoint(x: 122.34, y: 365.38), controlPoint1: CGPoint(x: 128.45, y: 367.25), controlPoint2: CGPoint(x: 125.65, y: 367.03))
             bezier7Path.addCurve(to: CGPoint(x: 116.74, y: 360.91), controlPoint1: CGPoint(x: 119.05, y: 363.74), controlPoint2: CGPoint(x: 116.74, y: 360.91))
             bezier7Path.addLine(to: CGPoint(x: 117.04, y: 348.63))
             bezier7Path.addLine(to: CGPoint(x: 74.53, y: 300.03))
             bezier7Path.addLine(to: CGPoint(x: 50.83, y: 303.81))
             bezier7Path.addLine(to: CGPoint(x: 43.07, y: 292))
             bezier7Path.addLine(to: CGPoint(x: 64.18, y: 288.34))
             bezier7Path.addLine(to: CGPoint(x: 92.54, y: 258.03))
             bezier7Path.addLine(to: CGPoint(x: 109.23, y: 264.27))
             bezier7Path.addLine(to: CGPoint(x: 160.88, y: 292.96))
             bezier7Path.addLine(to: CGPoint(x: 176.15, y: 303.11))
             bezier7Path.addCurve(to: CGPoint(x: 176.15, y: 341.41), controlPoint1: CGPoint(x: 176.12, y: 320.26), controlPoint2: CGPoint(x: 176.12, y: 333.02))
             bezier7Path.addLine(to: CGPoint(x: 176.28, y: 353.04))
             bezier7Path.close()
             bezier7Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier7Path.fill()
        }
        
        // MARK: - Travel And Places Category

         public class func drawTravelAndPlacesCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            let bezierPath = UIBezierPath()
            bezierPath.move(to: CGPoint(x: 221, y: 51))
            bezierPath.addLine(to: CGPoint(x: 189, y: 51))
            bezierPath.addLine(to: CGPoint(x: 189, y: 83))
            bezierPath.addLine(to: CGPoint(x: 221, y: 83))
            bezierPath.addLine(to: CGPoint(x: 221, y: 51))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 189, y: 136))
            bezierPath.addLine(to: CGPoint(x: 221, y: 136))
            bezierPath.addLine(to: CGPoint(x: 221, y: 104))
            bezierPath.addLine(to: CGPoint(x: 189, y: 104))
            bezierPath.addLine(to: CGPoint(x: 189, y: 136))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 263.67, y: 115.06))
            bezierPath.addLine(to: CGPoint(x: 263.67, y: 8))
            bezierPath.addLine(to: CGPoint(x: 92.56, y: 8))
            bezierPath.addLine(to: CGPoint(x: 92.56, y: 147.18))
            bezierPath.addLine(to: CGPoint(x: 7, y: 147.18))
            bezierPath.addLine(to: CGPoint(x: 7, y: 372))
            bezierPath.addLine(to: CGPoint(x: 28.39, y: 372))
            bezierPath.addLine(to: CGPoint(x: 28.39, y: 168.59))
            bezierPath.addLine(to: CGPoint(x: 113.94, y: 168.59))
            bezierPath.addLine(to: CGPoint(x: 113.94, y: 29.41))
            bezierPath.addLine(to: CGPoint(x: 242.28, y: 29.41))
            bezierPath.addLine(to: CGPoint(x: 242.28, y: 136.47))
            bezierPath.addLine(to: CGPoint(x: 263.67, y: 136.47))
            bezierPath.addLine(to: CGPoint(x: 370.61, y: 136.47))
            bezierPath.addLine(to: CGPoint(x: 370.61, y: 372))
            bezierPath.addLine(to: CGPoint(x: 392, y: 372))
            bezierPath.addLine(to: CGPoint(x: 392, y: 115.06))
            bezierPath.addLine(to: CGPoint(x: 263.67, y: 115.06))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 135, y: 136))
            bezierPath.addLine(to: CGPoint(x: 167, y: 136))
            bezierPath.addLine(to: CGPoint(x: 167, y: 104))
            bezierPath.addLine(to: CGPoint(x: 135, y: 104))
            bezierPath.addLine(to: CGPoint(x: 135, y: 136))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 317, y: 243))
            bezierPath.addLine(to: CGPoint(x: 349, y: 243))
            bezierPath.addLine(to: CGPoint(x: 349, y: 211))
            bezierPath.addLine(to: CGPoint(x: 317, y: 211))
            bezierPath.addLine(to: CGPoint(x: 317, y: 243))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 317, y: 190))
            bezierPath.addLine(to: CGPoint(x: 349, y: 190))
            bezierPath.addLine(to: CGPoint(x: 349, y: 158))
            bezierPath.addLine(to: CGPoint(x: 317, y: 158))
            bezierPath.addLine(to: CGPoint(x: 317, y: 190))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 167, y: 51))
            bezierPath.addLine(to: CGPoint(x: 135, y: 51))
            bezierPath.addLine(to: CGPoint(x: 135, y: 83))
            bezierPath.addLine(to: CGPoint(x: 167, y: 83))
            bezierPath.addLine(to: CGPoint(x: 167, y: 51))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 82, y: 190))
            bezierPath.addLine(to: CGPoint(x: 50, y: 190))
            bezierPath.addLine(to: CGPoint(x: 50, y: 222))
            bezierPath.addLine(to: CGPoint(x: 82, y: 222))
            bezierPath.addLine(to: CGPoint(x: 82, y: 190))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 290.5, y: 321))
            bezierPath.addCurve(to: CGPoint(x: 272, y: 302.5), controlPoint1: CGPoint(x: 280.28, y: 321), controlPoint2: CGPoint(x: 272, y: 312.72))
            bezierPath.addCurve(to: CGPoint(x: 290.5, y: 284), controlPoint1: CGPoint(x: 272, y: 292.29), controlPoint2: CGPoint(x: 280.28, y: 284))
            bezierPath.addCurve(to: CGPoint(x: 309, y: 302.5), controlPoint1: CGPoint(x: 300.72, y: 284), controlPoint2: CGPoint(x: 309, y: 292.29))
            bezierPath.addCurve(to: CGPoint(x: 290.5, y: 321), controlPoint1: CGPoint(x: 309, y: 312.72), controlPoint2: CGPoint(x: 300.72, y: 321))
            bezierPath.addLine(to: CGPoint(x: 290.5, y: 321))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 199.5, y: 265))
            bezierPath.addLine(to: CGPoint(x: 127, y: 265))
            bezierPath.addCurve(to: CGPoint(x: 199.5, y: 189), controlPoint1: CGPoint(x: 127, y: 226.35), controlPoint2: CGPoint(x: 127, y: 189))
            bezierPath.addCurve(to: CGPoint(x: 272, y: 265), controlPoint1: CGPoint(x: 272, y: 189), controlPoint2: CGPoint(x: 272, y: 226.35))
            bezierPath.addLine(to: CGPoint(x: 199.5, y: 265))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 253.6, y: 339))
            bezierPath.addLine(to: CGPoint(x: 146.4, y: 339))
            bezierPath.addCurve(to: CGPoint(x: 133, y: 328.5), controlPoint1: CGPoint(x: 139, y: 339), controlPoint2: CGPoint(x: 133, y: 334.3))
            bezierPath.addCurve(to: CGPoint(x: 146.4, y: 318), controlPoint1: CGPoint(x: 133, y: 322.7), controlPoint2: CGPoint(x: 139, y: 318))
            bezierPath.addLine(to: CGPoint(x: 253.6, y: 318))
            bezierPath.addCurve(to: CGPoint(x: 267, y: 328.5), controlPoint1: CGPoint(x: 261, y: 318), controlPoint2: CGPoint(x: 267, y: 322.7))
            bezierPath.addCurve(to: CGPoint(x: 253.6, y: 339), controlPoint1: CGPoint(x: 267, y: 334.3), controlPoint2: CGPoint(x: 261, y: 339))
            bezierPath.addLine(to: CGPoint(x: 253.6, y: 339))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 108.5, y: 321))
            bezierPath.addCurve(to: CGPoint(x: 90, y: 302.5), controlPoint1: CGPoint(x: 98.28, y: 321), controlPoint2: CGPoint(x: 90, y: 312.72))
            bezierPath.addCurve(to: CGPoint(x: 108.5, y: 284), controlPoint1: CGPoint(x: 90, y: 292.29), controlPoint2: CGPoint(x: 98.28, y: 284))
            bezierPath.addCurve(to: CGPoint(x: 127, y: 302.5), controlPoint1: CGPoint(x: 118.72, y: 284), controlPoint2: CGPoint(x: 127, y: 292.29))
            bezierPath.addCurve(to: CGPoint(x: 108.5, y: 321), controlPoint1: CGPoint(x: 127, y: 312.72), controlPoint2: CGPoint(x: 118.72, y: 321))
            bezierPath.addLine(to: CGPoint(x: 108.5, y: 321))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 304.63, y: 258.98))
            bezierPath.addLine(to: CGPoint(x: 296.07, y: 258.98))
            bezierPath.addLine(to: CGPoint(x: 296.07, y: 240.46))
            bezierPath.addCurve(to: CGPoint(x: 223.64, y: 168), controlPoint1: CGPoint(x: 296.07, y: 200.44), controlPoint2: CGPoint(x: 263.63, y: 168))
            bezierPath.addLine(to: CGPoint(x: 175.36, y: 168))
            bezierPath.addCurve(to: CGPoint(x: 102.93, y: 240.46), controlPoint1: CGPoint(x: 135.36, y: 168), controlPoint2: CGPoint(x: 102.93, y: 200.44))
            bezierPath.addLine(to: CGPoint(x: 102.93, y: 258.98))
            bezierPath.addLine(to: CGPoint(x: 94.37, y: 258.98))
            bezierPath.addCurve(to: CGPoint(x: 71, y: 284.44), controlPoint1: CGPoint(x: 81.46, y: 258.98), controlPoint2: CGPoint(x: 71, y: 270.39))
            bezierPath.addLine(to: CGPoint(x: 71, y: 335.39))
            bezierPath.addCurve(to: CGPoint(x: 81.71, y: 356.75), controlPoint1: CGPoint(x: 71, y: 344.36), controlPoint2: CGPoint(x: 75.27, y: 352.21))
            bezierPath.addLine(to: CGPoint(x: 81.71, y: 379.27))
            bezierPath.addCurve(to: CGPoint(x: 93.78, y: 391.36), controlPoint1: CGPoint(x: 81.71, y: 385.95), controlPoint2: CGPoint(x: 87.12, y: 391.36))
            bezierPath.addLine(to: CGPoint(x: 117.91, y: 391.36))
            bezierPath.addCurve(to: CGPoint(x: 129.99, y: 379.27), controlPoint1: CGPoint(x: 124.58, y: 391.36), controlPoint2: CGPoint(x: 129.99, y: 385.95))
            bezierPath.addLine(to: CGPoint(x: 129.99, y: 360.86))
            bezierPath.addLine(to: CGPoint(x: 269.01, y: 360.86))
            bezierPath.addLine(to: CGPoint(x: 269.01, y: 380.93))
            bezierPath.addCurve(to: CGPoint(x: 281.09, y: 393), controlPoint1: CGPoint(x: 269.01, y: 387.59), controlPoint2: CGPoint(x: 274.42, y: 393))
            bezierPath.addLine(to: CGPoint(x: 305.22, y: 393))
            bezierPath.addCurve(to: CGPoint(x: 317.29, y: 380.93), controlPoint1: CGPoint(x: 311.88, y: 393), controlPoint2: CGPoint(x: 317.29, y: 387.59))
            bezierPath.addLine(to: CGPoint(x: 317.29, y: 357.14))
            bezierPath.addLine(to: CGPoint(x: 316.63, y: 357.14))
            bezierPath.addCurve(to: CGPoint(x: 328, y: 335.39), controlPoint1: CGPoint(x: 323.42, y: 352.68), controlPoint2: CGPoint(x: 328, y: 344.66))
            bezierPath.addLine(to: CGPoint(x: 328, y: 284.44))
            bezierPath.addCurve(to: CGPoint(x: 304.63, y: 258.98), controlPoint1: CGPoint(x: 328, y: 270.39), controlPoint2: CGPoint(x: 317.54, y: 258.98))
            bezierPath.addLine(to: CGPoint(x: 304.63, y: 258.98))
            bezierPath.close()
            bezierPath.usesEvenOddFillRule = true
            tintColor.setFill()
            bezierPath.fill()
            
            context.endTransparencyLayer()
            context.restoreGState()
        }
        
        // MARK: - Objects Category

         public class func drawObjectsCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
             
             let bezierPath = UIBezierPath()
             bezierPath.move(to: CGPoint(x: 234.36, y: 197.39))
             bezierPath.addCurve(to: CGPoint(x: 229.92, y: 196.76), controlPoint1: CGPoint(x: 232.82, y: 197.39), controlPoint2: CGPoint(x: 231.34, y: 197.14))
             bezierPath.addLine(to: CGPoint(x: 208.94, y: 216.11))
             bezierPath.addLine(to: CGPoint(x: 208.94, y: 281.31))
             bezierPath.addLine(to: CGPoint(x: 188.6, y: 281.31))
             bezierPath.addLine(to: CGPoint(x: 188.6, y: 216.46))
             bezierPath.addLine(to: CGPoint(x: 167.34, y: 196.86))
             bezierPath.addCurve(to: CGPoint(x: 163.17, y: 197.39), controlPoint1: CGPoint(x: 166, y: 197.18), controlPoint2: CGPoint(x: 164.62, y: 197.39))
             bezierPath.addCurve(to: CGPoint(x: 145.38, y: 179.59), controlPoint1: CGPoint(x: 153.34, y: 197.39), controlPoint2: CGPoint(x: 145.38, y: 189.43))
             bezierPath.addCurve(to: CGPoint(x: 163.17, y: 161.79), controlPoint1: CGPoint(x: 145.38, y: 169.76), controlPoint2: CGPoint(x: 153.34, y: 161.79))
             bezierPath.addCurve(to: CGPoint(x: 180.97, y: 179.59), controlPoint1: CGPoint(x: 173.01, y: 161.79), controlPoint2: CGPoint(x: 180.97, y: 169.76))
             bezierPath.addCurve(to: CGPoint(x: 179.85, y: 185.63), controlPoint1: CGPoint(x: 180.97, y: 181.72), controlPoint2: CGPoint(x: 180.53, y: 183.73))
             bezierPath.addLine(to: CGPoint(x: 198.58, y: 202.9))
             bezierPath.addLine(to: CGPoint(x: 217.6, y: 185.35))
             bezierPath.addCurve(to: CGPoint(x: 216.57, y: 179.59), controlPoint1: CGPoint(x: 216.98, y: 183.54), controlPoint2: CGPoint(x: 216.57, y: 181.62))
             bezierPath.addCurve(to: CGPoint(x: 234.36, y: 161.79), controlPoint1: CGPoint(x: 216.57, y: 169.76), controlPoint2: CGPoint(x: 224.53, y: 161.79))
             bezierPath.addCurve(to: CGPoint(x: 252.16, y: 179.59), controlPoint1: CGPoint(x: 244.2, y: 161.79), controlPoint2: CGPoint(x: 252.16, y: 169.76))
             bezierPath.addCurve(to: CGPoint(x: 234.36, y: 197.39), controlPoint1: CGPoint(x: 252.16, y: 189.43), controlPoint2: CGPoint(x: 244.2, y: 197.39))
             bezierPath.addLine(to: CGPoint(x: 234.36, y: 197.39))
             bezierPath.close()
             bezierPath.usesEvenOddFillRule = true
             tintColor.setFill()
             bezierPath.fill()
             
             let rectanglePath = UIBezierPath(rect: CGRect(x: 156.15, y: 300.7, width: 86, height: 21))
             tintColor.setFill()
             rectanglePath.fill()
             
             let bezier2Path = UIBezierPath()
             bezier2Path.move(to: CGPoint(x: 158.11, y: 335.47))
             bezier2Path.addLine(to: CGPoint(x: 207.02, y: 335.47))
             bezier2Path.addCurve(to: CGPoint(x: 211.02, y: 339.47), controlPoint1: CGPoint(x: 209.22, y: 335.47), controlPoint2: CGPoint(x: 211.02, y: 337.27))
             bezier2Path.addLine(to: CGPoint(x: 211.02, y: 352.05))
             bezier2Path.addCurve(to: CGPoint(x: 207.02, y: 356.05), controlPoint1: CGPoint(x: 211.02, y: 354.26), controlPoint2: CGPoint(x: 209.22, y: 356.05))
             bezier2Path.addLine(to: CGPoint(x: 158.11, y: 356.05))
             bezier2Path.addLine(to: CGPoint(x: 158.11, y: 356.05))
             bezier2Path.addLine(to: CGPoint(x: 158.11, y: 335.47))
             bezier2Path.close()
             bezier2Path.usesEvenOddFillRule = true
             tintColor.setFill()
             bezier2Path.fill()
             
             context.saveGState()
             context.beginTransparencyLayer(auxiliaryInfo: nil)
             
             let clipPath = UIBezierPath()
             clipPath.move(to: CGPoint(x: 199.07, y: 7))
             clipPath.addCurve(to: CGPoint(x: 67, y: 135.67), controlPoint1: CGPoint(x: 123.58, y: 7), controlPoint2: CGPoint(x: 67, y: 64.73))
             clipPath.addCurve(to: CGPoint(x: 98.16, y: 229.46), controlPoint1: CGPoint(x: 67, y: 171.81), controlPoint2: CGPoint(x: 76.75, y: 210.58))
             clipPath.addCurve(to: CGPoint(x: 136.21, y: 300.54), controlPoint1: CGPoint(x: 118.3, y: 250.79), controlPoint2: CGPoint(x: 132.99, y: 273.33))
             clipPath.addLine(to: CGPoint(x: 138.69, y: 321.52))
             clipPath.addLine(to: CGPoint(x: 138.69, y: 368.62))
             clipPath.addCurve(to: CGPoint(x: 157.44, y: 389.73), controlPoint1: CGPoint(x: 138.69, y: 379), controlPoint2: CGPoint(x: 146.57, y: 387.88))
             clipPath.addCurve(to: CGPoint(x: 199.07, y: 393), controlPoint1: CGPoint(x: 167.3, y: 391.42), controlPoint2: CGPoint(x: 186.97, y: 393))
             clipPath.addCurve(to: CGPoint(x: 240.7, y: 389.73), controlPoint1: CGPoint(x: 211.17, y: 393), controlPoint2: CGPoint(x: 230.84, y: 391.42))
             clipPath.addCurve(to: CGPoint(x: 259.45, y: 368.62), controlPoint1: CGPoint(x: 251.57, y: 387.88), controlPoint2: CGPoint(x: 259.45, y: 379))
             clipPath.addLine(to: CGPoint(x: 259.45, y: 321.52))
             clipPath.addLine(to: CGPoint(x: 261.93, y: 300.54))
             clipPath.addCurve(to: CGPoint(x: 299.98, y: 229.46), controlPoint1: CGPoint(x: 265.15, y: 273.33), controlPoint2: CGPoint(x: 280.22, y: 249.95))
             clipPath.addCurve(to: CGPoint(x: 331.52, y: 135.67), controlPoint1: CGPoint(x: 321.34, y: 210.16), controlPoint2: CGPoint(x: 331.52, y: 171.81))
             clipPath.addCurve(to: CGPoint(x: 199.07, y: 7), controlPoint1: CGPoint(x: 331.52, y: 64.73), controlPoint2: CGPoint(x: 274.57, y: 7))
             clipPath.addLine(to: CGPoint(x: 199.07, y: 7))
             clipPath.close()
             clipPath.usesEvenOddFillRule = true
             clipPath.addClip()
             
             let bezier3Path = UIBezierPath()
             bezier3Path.move(to: CGPoint(x: 199.07, y: 7))
             bezier3Path.addCurve(to: CGPoint(x: 67, y: 135.67), controlPoint1: CGPoint(x: 123.58, y: 7), controlPoint2: CGPoint(x: 67, y: 64.73))
             bezier3Path.addCurve(to: CGPoint(x: 98.16, y: 229.46), controlPoint1: CGPoint(x: 67, y: 171.81), controlPoint2: CGPoint(x: 76.75, y: 210.58))
             bezier3Path.addCurve(to: CGPoint(x: 136.21, y: 300.54), controlPoint1: CGPoint(x: 118.3, y: 250.79), controlPoint2: CGPoint(x: 132.99, y: 273.33))
             bezier3Path.addLine(to: CGPoint(x: 138.69, y: 321.52))
             bezier3Path.addLine(to: CGPoint(x: 138.69, y: 368.62))
             bezier3Path.addCurve(to: CGPoint(x: 157.44, y: 389.73), controlPoint1: CGPoint(x: 138.69, y: 379), controlPoint2: CGPoint(x: 146.57, y: 387.88))
             bezier3Path.addCurve(to: CGPoint(x: 199.07, y: 393), controlPoint1: CGPoint(x: 167.3, y: 391.42), controlPoint2: CGPoint(x: 186.97, y: 393))
             bezier3Path.addCurve(to: CGPoint(x: 240.7, y: 389.73), controlPoint1: CGPoint(x: 211.17, y: 393), controlPoint2: CGPoint(x: 230.84, y: 391.42))
             bezier3Path.addCurve(to: CGPoint(x: 259.45, y: 368.62), controlPoint1: CGPoint(x: 251.57, y: 387.88), controlPoint2: CGPoint(x: 259.45, y: 379))
             bezier3Path.addLine(to: CGPoint(x: 259.45, y: 321.52))
             bezier3Path.addLine(to: CGPoint(x: 261.93, y: 300.54))
             bezier3Path.addCurve(to: CGPoint(x: 299.98, y: 229.46), controlPoint1: CGPoint(x: 265.15, y: 273.33), controlPoint2: CGPoint(x: 280.22, y: 249.95))
             bezier3Path.addCurve(to: CGPoint(x: 331.52, y: 135.67), controlPoint1: CGPoint(x: 321.34, y: 210.16), controlPoint2: CGPoint(x: 331.52, y: 171.81))
             bezier3Path.addCurve(to: CGPoint(x: 199.07, y: 7), controlPoint1: CGPoint(x: 331.52, y: 64.73), controlPoint2: CGPoint(x: 274.57, y: 7))
             bezier3Path.addLine(to: CGPoint(x: 199.07, y: 7))
             bezier3Path.close()
             tintColor.setStroke()
             bezier3Path.lineWidth = 40
             bezier3Path.miterLimit = 40
             bezier3Path.stroke()

             context.endTransparencyLayer()
             context.restoreGState()
        }
        
        // MARK: - Symbols Category

         public class func drawSymbolsCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            
            let clipPath = UIBezierPath()
            clipPath.move(to: CGPoint(x: 98, y: 10))
            clipPath.addLine(to: CGPoint(x: 301, y: 10))
            clipPath.addCurve(to: CGPoint(x: 390, y: 99), controlPoint1: CGPoint(x: 350.15, y: 10), controlPoint2: CGPoint(x: 390, y: 49.85))
            clipPath.addLine(to: CGPoint(x: 390, y: 302))
            clipPath.addCurve(to: CGPoint(x: 301, y: 391), controlPoint1: CGPoint(x: 390, y: 351.15), controlPoint2: CGPoint(x: 350.15, y: 391))
            clipPath.addLine(to: CGPoint(x: 98, y: 391))
            clipPath.addCurve(to: CGPoint(x: 9, y: 302), controlPoint1: CGPoint(x: 48.85, y: 391), controlPoint2: CGPoint(x: 9, y: 351.15))
            clipPath.addLine(to: CGPoint(x: 9, y: 99))
            clipPath.addCurve(to: CGPoint(x: 98, y: 10), controlPoint1: CGPoint(x: 9, y: 49.85), controlPoint2: CGPoint(x: 48.85, y: 10))
            clipPath.close()
            clipPath.usesEvenOddFillRule = true
            clipPath.addClip()
            
            let bezier2Path = UIBezierPath()
            bezier2Path.move(to: CGPoint(x: 98, y: 10))
            bezier2Path.addLine(to: CGPoint(x: 301, y: 10))
            bezier2Path.addCurve(to: CGPoint(x: 390, y: 99), controlPoint1: CGPoint(x: 350.15, y: 10), controlPoint2: CGPoint(x: 390, y: 49.85))
            bezier2Path.addLine(to: CGPoint(x: 390, y: 302))
            bezier2Path.addCurve(to: CGPoint(x: 301, y: 391), controlPoint1: CGPoint(x: 390, y: 351.15), controlPoint2: CGPoint(x: 350.15, y: 391))
            bezier2Path.addLine(to: CGPoint(x: 98, y: 391))
            bezier2Path.addCurve(to: CGPoint(x: 9, y: 302), controlPoint1: CGPoint(x: 48.85, y: 391), controlPoint2: CGPoint(x: 9, y: 351.15))
            bezier2Path.addLine(to: CGPoint(x: 9, y: 99))
            bezier2Path.addCurve(to: CGPoint(x: 98, y: 10), controlPoint1: CGPoint(x: 9, y: 49.85), controlPoint2: CGPoint(x: 48.85, y: 10))
            bezier2Path.close()
            tintColor.setStroke()
            bezier2Path.lineWidth = 40
            bezier2Path.miterLimit = 40
            bezier2Path.stroke()
            
            context.endTransparencyLayer()
            context.restoreGState()
            
            let bezierPath = UIBezierPath()
            bezierPath.move(to: CGPoint(x: 229.85, y: 247.93))
            bezierPath.addCurve(to: CGPoint(x: 240.53, y: 231.67), controlPoint1: CGPoint(x: 229.85, y: 238.58), controlPoint2: CGPoint(x: 233.37, y: 231.67))
            bezierPath.addCurve(to: CGPoint(x: 251.05, y: 248.09), controlPoint1: CGPoint(x: 247.4, y: 231.67), controlPoint2: CGPoint(x: 251.05, y: 238.19))
            bezierPath.addLine(to: CGPoint(x: 251.05, y: 248.78))
            bezierPath.addCurve(to: CGPoint(x: 240.45, y: 265.26), controlPoint1: CGPoint(x: 251.05, y: 258.75), controlPoint2: CGPoint(x: 247.1, y: 265.26))
            bezierPath.addCurve(to: CGPoint(x: 229.85, y: 248.62), controlPoint1: CGPoint(x: 233.67, y: 265.26), controlPoint2: CGPoint(x: 229.85, y: 258.59))
            bezierPath.addLine(to: CGPoint(x: 229.85, y: 247.93))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 239.8, y: 279.66))
            bezierPath.addCurve(to: CGPoint(x: 264.55, y: 249.68), controlPoint1: CGPoint(x: 255.6, y: 279.66), controlPoint2: CGPoint(x: 264.55, y: 265.87))
            bezierPath.addLine(to: CGPoint(x: 264.55, y: 247.17))
            bezierPath.addCurve(to: CGPoint(x: 239.97, y: 217.28), controlPoint1: CGPoint(x: 264.55, y: 230.44), controlPoint2: CGPoint(x: 255.43, y: 217.28))
            bezierPath.addCurve(to: CGPoint(x: 215.4, y: 246.99), controlPoint1: CGPoint(x: 224.52, y: 217.28), controlPoint2: CGPoint(x: 215.4, y: 230.61))
            bezierPath.addLine(to: CGPoint(x: 215.4, y: 249.5))
            bezierPath.addCurve(to: CGPoint(x: 239.8, y: 279.66), controlPoint1: CGPoint(x: 215.4, y: 266.32), controlPoint2: CGPoint(x: 224.25, y: 279.66))
            bezierPath.addLine(to: CGPoint(x: 239.8, y: 279.66))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 313.69, y: 311.16))
            bezierPath.addCurve(to: CGPoint(x: 303.08, y: 327.64), controlPoint1: CGPoint(x: 313.69, y: 321.13), controlPoint2: CGPoint(x: 309.74, y: 327.64))
            bezierPath.addCurve(to: CGPoint(x: 292.49, y: 311), controlPoint1: CGPoint(x: 296.29, y: 327.64), controlPoint2: CGPoint(x: 292.49, y: 320.97))
            bezierPath.addLine(to: CGPoint(x: 292.49, y: 310.31))
            bezierPath.addCurve(to: CGPoint(x: 303.16, y: 294.05), controlPoint1: CGPoint(x: 292.49, y: 300.95), controlPoint2: CGPoint(x: 295.99, y: 294.05))
            bezierPath.addCurve(to: CGPoint(x: 313.69, y: 310.46), controlPoint1: CGPoint(x: 310.03, y: 294.05), controlPoint2: CGPoint(x: 313.69, y: 300.57))
            bezierPath.addLine(to: CGPoint(x: 313.69, y: 311.16))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 303.57, y: 280.62))
            bezierPath.addCurve(to: CGPoint(x: 279, y: 310.33), controlPoint1: CGPoint(x: 288.12, y: 280.62), controlPoint2: CGPoint(x: 279, y: 293.95))
            bezierPath.addLine(to: CGPoint(x: 279, y: 312.83))
            bezierPath.addCurve(to: CGPoint(x: 303.4, y: 343), controlPoint1: CGPoint(x: 279, y: 329.67), controlPoint2: CGPoint(x: 287.85, y: 343))
            bezierPath.addCurve(to: CGPoint(x: 328.15, y: 313.02), controlPoint1: CGPoint(x: 319.2, y: 343), controlPoint2: CGPoint(x: 328.15, y: 329.21))
            bezierPath.addLine(to: CGPoint(x: 328.15, y: 310.51))
            bezierPath.addCurve(to: CGPoint(x: 303.57, y: 280.62), controlPoint1: CGPoint(x: 328.15, y: 293.77), controlPoint2: CGPoint(x: 319.03, y: 280.62))
            bezierPath.addLine(to: CGPoint(x: 303.57, y: 280.62))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 67, y: 80.99))
            bezierPath.addLine(to: CGPoint(x: 203.84, y: 80.99))
            bezierPath.addLine(to: CGPoint(x: 203.84, y: 57))
            bezierPath.addLine(to: CGPoint(x: 67, y: 57))
            bezierPath.addLine(to: CGPoint(x: 67, y: 80.99))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 67, y: 120.12))
            bezierPath.addLine(to: CGPoint(x: 123.34, y: 120.31))
            bezierPath.addLine(to: CGPoint(x: 123.34, y: 193.28))
            bezierPath.addLine(to: CGPoint(x: 147.49, y: 193.28))
            bezierPath.addLine(to: CGPoint(x: 147.49, y: 120.39))
            bezierPath.addLine(to: CGPoint(x: 203.84, y: 120.58))
            bezierPath.addLine(to: CGPoint(x: 203.84, y: 96.35))
            bezierPath.addLine(to: CGPoint(x: 67, y: 96.35))
            bezierPath.addLine(to: CGPoint(x: 67, y: 120.12))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 291.4, y: 158.49))
            bezierPath.addLine(to: CGPoint(x: 291.4, y: 80.89))
            bezierPath.addCurve(to: CGPoint(x: 319.21, y: 119), controlPoint1: CGPoint(x: 291.4, y: 80.89), controlPoint2: CGPoint(x: 317.43, y: 94.16))
            bezierPath.addCurve(to: CGPoint(x: 309.69, y: 157.8), controlPoint1: CGPoint(x: 320.59, y: 138.35), controlPoint2: CGPoint(x: 302.01, y: 150.34))
            bezierPath.addCurve(to: CGPoint(x: 331.98, y: 118.13), controlPoint1: CGPoint(x: 309.69, y: 157.8), controlPoint2: CGPoint(x: 331.58, y: 137.52))
            bezierPath.addCurve(to: CGPoint(x: 276.03, y: 57), controlPoint1: CGPoint(x: 332.87, y: 74.79), controlPoint2: CGPoint(x: 304.58, y: 57))
            bezierPath.addLine(to: CGPoint(x: 276.03, y: 145.37))
            bezierPath.addCurve(to: CGPoint(x: 248.17, y: 151.27), controlPoint1: CGPoint(x: 276.03, y: 145.37), controlPoint2: CGPoint(x: 267.19, y: 141.57))
            bezierPath.addCurve(to: CGPoint(x: 230.02, y: 186.89), controlPoint1: CGPoint(x: 229.13, y: 160.97), controlPoint2: CGPoint(x: 224.69, y: 175.91))
            bezierPath.addCurve(to: CGPoint(x: 291.4, y: 158.49), controlPoint1: CGPoint(x: 236.66, y: 200.59), controlPoint2: CGPoint(x: 291.4, y: 197.28))
            bezierPath.addLine(to: CGPoint(x: 291.4, y: 158.49))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 328.15, y: 218.23))
            bezierPath.addLine(to: CGPoint(x: 309.95, y: 218.23))
            bezierPath.addLine(to: CGPoint(x: 264.88, y: 278.15))
            bezierPath.addLine(to: CGPoint(x: 217.33, y: 343))
            bezierPath.addLine(to: CGPoint(x: 236.17, y: 343))
            bezierPath.addLine(to: CGPoint(x: 281.41, y: 280.27))
            bezierPath.addLine(to: CGPoint(x: 328.15, y: 218.23))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 126.62, y: 328.6))
            bezierPath.addCurve(to: CGPoint(x: 101.69, y: 307.39), controlPoint1: CGPoint(x: 113.72, y: 328.6), controlPoint2: CGPoint(x: 101.69, y: 321.62))
            bezierPath.addCurve(to: CGPoint(x: 117.55, y: 285.46), controlPoint1: CGPoint(x: 101.69, y: 297), controlPoint2: CGPoint(x: 108.14, y: 290.66))
            bezierPath.addCurve(to: CGPoint(x: 121.3, y: 283.5), controlPoint1: CGPoint(x: 118.78, y: 284.74), controlPoint2: CGPoint(x: 120, y: 284.12))
            bezierPath.addLine(to: CGPoint(x: 152.76, y: 318.31))
            bezierPath.addCurve(to: CGPoint(x: 126.62, y: 328.6), controlPoint1: CGPoint(x: 145.97, y: 325.55), controlPoint2: CGPoint(x: 135.16, y: 328.6))
            bezierPath.addLine(to: CGPoint(x: 126.62, y: 328.6))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 129.59, y: 231.67))
            bezierPath.addCurve(to: CGPoint(x: 145.05, y: 246.52), controlPoint1: CGPoint(x: 138.48, y: 231.67), controlPoint2: CGPoint(x: 145.05, y: 237.57))
            bezierPath.addCurve(to: CGPoint(x: 126.57, y: 267.18), controlPoint1: CGPoint(x: 145.05, y: 256.35), controlPoint2: CGPoint(x: 137.33, y: 261.72))
            bezierPath.addCurve(to: CGPoint(x: 114.22, y: 246.61), controlPoint1: CGPoint(x: 117.24, y: 257.96), controlPoint2: CGPoint(x: 114.22, y: 252.78))
            bezierPath.addCurve(to: CGPoint(x: 129.59, y: 231.67), controlPoint1: CGPoint(x: 114.22, y: 238.02), controlPoint2: CGPoint(x: 120.44, y: 231.67))
            bezierPath.addLine(to: CGPoint(x: 129.59, y: 231.67))
            bezierPath.close()
            bezierPath.move(to: CGPoint(x: 182.85, y: 276.98))
            bezierPath.addLine(to: CGPoint(x: 182.85, y: 272.39))
            bezierPath.addLine(to: CGPoint(x: 167.19, y: 272.39))
            bezierPath.addLine(to: CGPoint(x: 167.19, y: 276.44))
            bezierPath.addCurve(to: CGPoint(x: 162.01, y: 306.03), controlPoint1: CGPoint(x: 167.19, y: 289.15), controlPoint2: CGPoint(x: 165.79, y: 299.19))
            bezierPath.addLine(to: CGPoint(x: 134.66, y: 276.53))
            bezierPath.addCurve(to: CGPoint(x: 159.81, y: 245.6), controlPoint1: CGPoint(x: 148.11, y: 269.33), controlPoint2: CGPoint(x: 159.81, y: 260.71))
            bezierPath.addCurve(to: CGPoint(x: 128.58, y: 218.23), controlPoint1: CGPoint(x: 159.81, y: 228.81), controlPoint2: CGPoint(x: 145.74, y: 218.23))
            bezierPath.addCurve(to: CGPoint(x: 97.36, y: 245.51), controlPoint1: CGPoint(x: 110.38, y: 218.23), controlPoint2: CGPoint(x: 97.36, y: 230.14))
            bezierPath.addCurve(to: CGPoint(x: 112.14, y: 273.33), controlPoint1: CGPoint(x: 97.36, y: 256.53), controlPoint2: CGPoint(x: 104.23, y: 264.89))
            bezierPath.addCurve(to: CGPoint(x: 107.39, y: 275.82), controlPoint1: CGPoint(x: 110.47, y: 274.13), controlPoint2: CGPoint(x: 108.88, y: 274.94))
            bezierPath.addCurve(to: CGPoint(x: 84.35, y: 308.79), controlPoint1: CGPoint(x: 94.02, y: 283.28), controlPoint2: CGPoint(x: 84.35, y: 292.97))
            bezierPath.addCurve(to: CGPoint(x: 124.89, y: 343), controlPoint1: CGPoint(x: 84.35, y: 330.03), controlPoint2: CGPoint(x: 101.85, y: 343))
            bezierPath.addCurve(to: CGPoint(x: 162.62, y: 329.49), controlPoint1: CGPoint(x: 137.12, y: 343), controlPoint2: CGPoint(x: 151.36, y: 339.27))
            bezierPath.addLine(to: CGPoint(x: 173.09, y: 340.6))
            bezierPath.addLine(to: CGPoint(x: 194.2, y: 340.6))
            bezierPath.addLine(to: CGPoint(x: 173.09, y: 317.94))
            bezierPath.addCurve(to: CGPoint(x: 182.85, y: 276.98), controlPoint1: CGPoint(x: 179.86, y: 307.72), controlPoint2: CGPoint(x: 182.85, y: 293.68))
            bezierPath.addLine(to: CGPoint(x: 182.85, y: 276.98))
            bezierPath.close()
            bezierPath.usesEvenOddFillRule = true
            tintColor.setFill()
            bezierPath.fill()

            context.endTransparencyLayer()
            context.restoreGState()
        }
        
        // MARK: - Flags Category

         public class func drawFlagsCategory(frame targetFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400), resizing: ResizingBehavior = .aspectFit, tintColor: UIColor) {
             guard let context = UIGraphicsGetCurrentContext() else { return }
            
            context.saveGState()
            let resizedFrame: CGRect = resizing.apply(rect: CGRect(x: 0, y: 0, width: 400, height: 400), target: targetFrame)
            context.translateBy(x: resizedFrame.minX, y: resizedFrame.minY)
            context.scaleBy(x: resizedFrame.width / 400, y: resizedFrame.height / 400)
            
             context.saveGState()
             context.beginTransparencyLayer(auxiliaryInfo: nil)
             
             let clipPath = UIBezierPath()
             clipPath.move(to: CGPoint(x: 45.99, y: 241.38))
             clipPath.addLine(to: CGPoint(x: 45.99, y: 20.39))
             clipPath.addCurve(to: CGPoint(x: 353.99, y: 30.91), controlPoint1: CGPoint(x: 169.21, y: 95.34), controlPoint2: CGPoint(x: 230.81, y: -44.01))
             clipPath.addLine(to: CGPoint(x: 353.99, y: 230.88))
             clipPath.addCurve(to: CGPoint(x: 68.03, y: 251.38), controlPoint1: CGPoint(x: 238.37, y: 168.45), controlPoint2: CGPoint(x: 177.01, y: 291.08))
             clipPath.addLine(to: CGPoint(x: 67.99, y: 394))
             clipPath.addLine(to: CGPoint(x: 45.99, y: 394))
             clipPath.addLine(to: CGPoint(x: 45.99, y: 241.4))
             clipPath.addLine(to: CGPoint(x: 45.99, y: 241.38))
             clipPath.close()
             clipPath.usesEvenOddFillRule = true
             clipPath.addClip()
             
             let bezierPath = UIBezierPath()
             bezierPath.move(to: CGPoint(x: 45.99, y: 241.38))
             bezierPath.addLine(to: CGPoint(x: 45.99, y: 20.39))
             bezierPath.addCurve(to: CGPoint(x: 353.99, y: 30.91), controlPoint1: CGPoint(x: 169.21, y: 95.34), controlPoint2: CGPoint(x: 230.81, y: -44.01))
             bezierPath.addLine(to: CGPoint(x: 353.99, y: 230.88))
             bezierPath.addCurve(to: CGPoint(x: 68.03, y: 251.38), controlPoint1: CGPoint(x: 238.37, y: 168.45), controlPoint2: CGPoint(x: 177.01, y: 291.08))
             bezierPath.addLine(to: CGPoint(x: 67.99, y: 394))
             bezierPath.addLine(to: CGPoint(x: 45.99, y: 394))
             bezierPath.addLine(to: CGPoint(x: 45.99, y: 241.4))
             bezierPath.addLine(to: CGPoint(x: 45.99, y: 241.38))
             bezierPath.close()
             tintColor.setStroke()
             bezierPath.lineWidth = 44
             bezierPath.miterLimit = 44
             bezierPath.stroke()
             
             context.endTransparencyLayer()
             context.restoreGState()
        }
    }
}
