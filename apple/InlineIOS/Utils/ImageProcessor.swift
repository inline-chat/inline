import ImageIO
import UIKit
import UniformTypeIdentifiers

actor ImageProcessor {
  static let shared = ImageProcessor()

  func processImage(_ image: UIImage) async -> (UIImage, Data?) {
    let resizedImage = resizeImageToOptimalSize(image)
    let optimizedData = optimizePNG(resizedImage)
    return (resizedImage, optimizedData)
  }

  private func resizeImageToOptimalSize(_ image: UIImage) -> UIImage {
    let optimalDimension: CGFloat = 450

    let originalSize = image.size

    if originalSize.width <= optimalDimension && originalSize.height <= optimalDimension {
      return image
    }

    let aspectRatio = originalSize.width / originalSize.height
    var newSize: CGSize

    if originalSize.width > originalSize.height {
      newSize = CGSize(width: optimalDimension, height: optimalDimension / aspectRatio)
    } else {
      newSize = CGSize(width: optimalDimension * aspectRatio, height: optimalDimension)
    }

    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
    image.draw(in: CGRect(origin: .zero, size: newSize))
    let resizedImage = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()

    return resizedImage
  }

  private func optimizePNG(_ image: UIImage) -> Data? {
    let options: [CFString: Any] = [
      kCGImagePropertyPNGInterlaceType: 1
    ]

    let data = NSMutableData()

    guard let destination = CGImageDestinationCreateWithData(
      data as CFMutableData,
      UTType.png.identifier as CFString,
      1,
      nil
    ),
      let cgImage = image.cgImage
    else {
      return nil
    }

    CGImageDestinationSetProperties(destination, options as CFDictionary)
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

    if CGImageDestinationFinalize(destination) {
      return data as Data
    }

    return image.pngData()
  }
}
