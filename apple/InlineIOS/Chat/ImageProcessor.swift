import UIKit
import UniformTypeIdentifiers
import ImageIO

class ImageProcessor {
    static let shared = ImageProcessor()
    private let processingQueue = DispatchQueue(label: "com.app.imageProcessing",
                                               qos: .userInitiated,
                                               attributes: .concurrent)
    
    func processImage(_ image: UIImage, completion: @escaping (UIImage?, Data?) -> Void) {
        processingQueue.async {
            let resizedImage = self.resizeImageToOptimalSize(image)
            
            guard let optimizedData = self.optimizePNG(resizedImage) else {
                DispatchQueue.main.async {
                    completion(resizedImage, nil)
                }
                return
            }
            
            DispatchQueue.main.async {
                completion(resizedImage, optimizedData)
            }
        }
    }
    
    func resizeImageToOptimalSize(_ image: UIImage) -> UIImage {
        let optimalDimension: CGFloat = 512
        
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
    
    func optimizePNG(_ image: UIImage) -> Data? {
        
        let options: [CFString: Any] = [
            kCGImagePropertyPNGInterlaceType: 1
        ]
        
        let data = NSMutableData()
        
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil),
              let cgImage = image.cgImage else {
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
