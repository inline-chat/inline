import AppKit
import CoreMedia
import CoreImage
import ImageIO
import ScreenCaptureKit

/// What the window server composited for one frame of the lab window, read from its pixels: the truth for blank
/// strips and rows without text, whatever the main thread was doing (responsive scrolling moves content off it).
struct ScreenFrame: Sendable {
  var t: CFTimeInterval
  /// The longest white stretch in the usable area (no row there), in points.
  var blank: Double
  /// Rows (a run of one row shade) wholly inside the usable area, or at least 30 pt of one, with no text pixel.
  var textless: Int
  var rows: Int
  /// Where row shades change, top to bottom (points from the usable top): equal lists mean nothing moved.
  var edges: [Double]
}

/// Captures the lab window with ScreenCaptureKit at the display's rate and analyses each frame on a background queue.
final class ScreenWatch: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  struct Geometry: Sendable {
    /// Points from the image's top to the list's top (the title bar).
    var contentTop: Double
    var usableTop: Double
    var usableBottom: Double
    var width: Double
  }

  private var stream: SCStream?
  private let queue = DispatchQueue(label: "screen-watch", qos: .userInitiated)
  private let lock = NSLock()
  private var frames: [ScreenFrame] = []
  private var geometry: Geometry
  private(set) var failure: String?
  /// Frames showing a blank strip or a row without text are saved as PNGs under this prefix (a few per run).
  var dumpPrefix: String?
  private var dumped = 0

  init(geometry: Geometry) {
    self.geometry = geometry
  }

  static var isAvailable: Bool { CGPreflightScreenCaptureAccess() }

  func start(windowNumber: Int, size: CGSize, scale: CGFloat, rate: Int) async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else {
        failure = "window not found"
        return
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let config = SCStreamConfiguration()
      config.width = Int(size.width * scale)
      config.height = Int(size.height * scale)
      config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(30, rate)))
      config.pixelFormat = kCVPixelFormatType_32BGRA
      config.showsCursor = false
      config.queueDepth = 8
      config.ignoreShadowsSingleWindow = true
      let stream = SCStream(filter: filter, configuration: config, delegate: self)
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
      try await stream.startCapture()
      self.stream = stream
    } catch {
      failure = "\(error)"
    }
  }

  func stop() async -> [ScreenFrame] {
    if let stream { try? await stream.stopCapture() }
    stream = nil
    // Let the queue drain.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    return lock.withLock { frames }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    failure = "\(error)"
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
          as? [[SCStreamFrameInfo: Any]],
          let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
          let buffer = sampleBuffer.imageBuffer
    else { return }
    // The refresh the frame was shown at (mach time), else the sample's presentation time.
    var t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    if let display = attachments.first?[.displayTime] as? UInt64 {
      var info = mach_timebase_info_data_t()
      mach_timebase_info(&info)
      t = Double(display) * Double(info.numer) / Double(info.denom) / 1e9
    }
    if let frame = analyse(buffer, t: t) {
      if let prefix = dumpPrefix, dumped < 4,
         frame.blank > 0.5 || frame.textless > 0 || (dumped == 0 && CommandLine.arguments.contains("--dump-first")) {
        dumped += 1
        save(buffer, to: "\(prefix)-\(dumped)-blank\(Int(frame.blank))-textless\(frame.textless).png")
      }
      lock.lock()
      frames.append(frame)
      lock.unlock()
    }
  }

  private func save(_ buffer: CVPixelBuffer, to path: String) {
    let image = CIImage(cvPixelBuffer: buffer)
    let context = CIContext()
    guard let cg = context.createCGImage(image, from: image.extent) else { return }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, cg, nil)
    CGImageDestinationFinalize(destination)
  }

  private func analyse(_ buffer: CVPixelBuffer, t: Double) -> ScreenFrame? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let g = geometry
    let scale = Double(width) / g.width
    func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
      let p = pixels + y * stride + x * 4
      return (Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
    }
    enum Kind { case white, shade0, shade1, other }
    func kind(_ c: (r: Double, g: Double, b: Double)) -> Kind {
      if c.r > 0.97, c.g > 0.97, c.b > 0.97 { return .white }
      if abs(c.r - 0.86) < 0.05, abs(c.g - 0.91) < 0.05, c.b > 0.95 { return .shade0 }
      if c.r > 0.95, abs(c.g - 0.92) < 0.05, abs(c.b - 0.82) < 0.05 { return .shade1 }
      return .other
    }
    let top = Int(((g.contentTop + g.usableTop) * scale).rounded(.up)) + 1
    let bottom = min(height - 1, Int(((g.contentTop + g.usableBottom) * scale).rounded(.down)) - 1)
    guard bottom > top else { return nil }
    let sampleX = Int(6 * scale)
    let textFrom = Int(16 * scale)
    let textTo = max(textFrom + 1, Int((g.width - 22) * scale))
    var blankRun = 0
    var blankMax = 0
    var runs: [(kind: Kind, from: Int, to: Int)] = []
    for y in top ... bottom {
      let k = kind(px(sampleX, y))
      if k == .white {
        blankRun += 1
        blankMax = max(blankMax, blankRun)
      } else {
        blankRun = 0
      }
      if let last = runs.last, last.kind == k {
        runs[runs.count - 1].to = y
      } else {
        runs.append((k, y, y))
      }
    }
    var textless = 0
    var rowCount = 0
    for (i, run) in runs.enumerated() where run.kind == .shade0 || run.kind == .shade1 {
      let inside = i > 0 && i < runs.count - 1
      let tall = Double(run.to - run.from + 1) / scale >= 30
      guard inside || tall else { continue }
      rowCount += 1
      var found = false
      var y = run.from
      while y <= run.to, !found {
        let row = pixels + y * stride
        var x = textFrom
        while x < textTo {
          let p = row + x * 4
          // Text is black on light bubbles: any dark pixel is text.
          if Int(p[0]) + Int(p[1]) + Int(p[2]) < 270 {
            found = true
            break
          }
          x += 1
        }
        y += 1
      }
      if !found { textless += 1 }
    }
    var edges: [Double] = []
    for (i, run) in runs.enumerated() where i > 0 && (run.kind == .shade0 || run.kind == .shade1) {
      edges.append(Double(run.from - top) / scale)
    }
    return ScreenFrame(t: t, blank: Double(blankMax) / scale, textless: textless, rows: rowCount, edges: edges)
  }
}
