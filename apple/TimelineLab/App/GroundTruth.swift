import CoreImage
import CoreMedia
import QuartzCore
import ReplayKit
import UIKit

/// Geometry the pixel analyser needs (screen points). Captured on the main actor, read off-main.
struct GTGeometry: Sendable {
  var screenW: Double = 375
  var counterY: Double = 0        // screen y of the counter bits' centre
  var counterX0: Double = 0       // screen x of bit 0's centre
  var bitStep: Double = 14
  var scanX: Double = 300         // column scanned for composer / keyboard
  var scanFromY: Double = 100     // start of the scan (below the nav bar)
  var composerH: Double = 50
  var screenH: Double = 667
}

/// Real composited frames from ReplayKit in-app capture, analysed per frame:
/// frame counter (12 bits) → which display-link frame is on screen; composer top (magenta) and keyboard top
/// (first row below the composer that is neither magenta nor the green gap colour).
final class GroundTruth: @unchecked Sendable {
  static let shared = GroundTruth()
  private let lock = NSLock()
  private var rows: [String] = []
  private var geometry = GTGeometry()
  private var saveRequests: [(String, Int)] = []
  private var savedCount: [String: Int] = [:]
  private var formatLogged = false
  private let ci = CIContext()
  var running = false

  func setGeometry(_ g: GTGeometry) { lock.lock(); geometry = g; lock.unlock() }
  func requestFrames(_ label: String, count: Int) { lock.lock(); saveRequests.append((label, count)); lock.unlock() }

  @MainActor func start(completion: @escaping @MainActor (Bool) -> Void) {
    let rec = RPScreenRecorder.shared()
    rec.isMicrophoneEnabled = false
    lock.lock(); rows = ["pts,counter,composerTopPx,kbTopPx,scale,composerTopPt,kbTopPt,residualPt,status"]; lock.unlock()
    rec.startCapture(handler: GroundTruth.makeHandler(self), completionHandler: { err in
      DispatchQueue.main.async {
        Lab.log("GT startCapture err=\(String(describing: err))")
        self.running = err == nil
        completion(err == nil)
      }
    })
  }

  nonisolated static func resumer(_ c: CheckedContinuation<Void, Never>) -> @Sendable (Error?) -> Void {
    { _ in c.resume() }
  }

  nonisolated static func makeHandler(_ gt: GroundTruth) -> @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
    { buf, type, err in
      guard type == .video, err == nil else { return }
      gt.analyse(buf)
    }
  }

  @MainActor func stop(name: String) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      RPScreenRecorder.shared().stopCapture(handler: GroundTruth.resumer(c))
    }
    running = false
    save(name: name)
  }

  @MainActor func save(name: String) {
    lock.lock(); let text = rows.joined(separator: "\n"); lock.unlock()
    Lab.write("\(name)_gt.csv", text)
  }

  private func analyse(_ sb: CMSampleBuffer) {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    lock.lock(); let g = geometry; var req = saveRequests.first; lock.unlock()

    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    if !formatLogged {
      formatLogged = true
      let f = String(format: "%c%c%c%c", (fmt >> 24) & 0xff, (fmt >> 16) & 0xff, (fmt >> 8) & 0xff, fmt & 0xff)
      print("[LAB] GT pixel format \(f) \(w)x\(h)")
    }
    let scale = Double(w) / g.screenW

    let reader: (Int, Int) -> (Double, Double, Double)
    if fmt == kCVPixelFormatType_32BGRA {
      let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
      let bpr = CVPixelBufferGetBytesPerRow(pb)
      reader = { x, y in let p = base + y * bpr + x * 4; return (Double(p[2]), Double(p[1]), Double(p[0])) }
    } else {
      let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
      let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
      let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
      let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
      reader = { x, y in
        var Y = Double(yb[y * ybpr + x])
        var U = Double(cb[(y / 2) * cbpr + (x / 2) * 2]) - 128
        var V = Double(cb[(y / 2) * cbpr + (x / 2) * 2 + 1]) - 128
        if !full { Y = (Y - 16) * 255 / 219; U *= 255 / 224; V *= 255 / 224 }
        return (Y + 1.5748 * V, Y - 0.1873 * U - 0.4681 * V, Y + 1.8556 * U)
      }
    }
    func isMagenta(_ c: (Double, Double, Double)) -> Bool { c.0 > 170 && c.2 > 170 && c.1 < 110 }
    func isGreen(_ c: (Double, Double, Double)) -> Bool { c.1 > 170 && c.0 < 110 && c.2 < 110 }

    // counter
    var counter = 0
    let cy = Int(g.counterY * scale)
    for i in 0..<12 {
      let x = Int((g.counterX0 + Double(i) * g.bitStep) * scale)
      let c = reader(min(max(x, 0), w - 1), min(max(cy, 0), h - 1))
      counter = (counter << 1) | ((c.0 + c.1 + c.2) / 3 > 128 ? 1 : 0)
    }
    // scan
    let sx = min(Int(g.scanX * scale), w - 1)
    var y = Int(g.scanFromY * scale)
    var composerTop = -1
    while y < h - 2 {
      if isMagenta(reader(sx, y)) && isMagenta(reader(sx, y + 1)) && isMagenta(reader(sx, y + 2)) { composerTop = y; break }
      y += 1
    }
    var kbTop = h
    var status = "ok"
    if composerTop < 0 { status = "nocomposer" } else {
      y = composerTop + 3
      while y < h - 2 {
        let a = reader(sx, y), b = reader(sx, y + 1), c = reader(sx, y + 2)
        let other = { (q: (Double, Double, Double)) in !isMagenta(q) && !isGreen(q) }
        if other(a) && other(b) && other(c) { kbTop = y; break }
        y += 1
      }
    }
    let ctPt = Double(composerTop) / scale, kbPt = Double(kbTop) / scale
    let residual = composerTop < 0 ? Double.nan : (ctPt + g.composerH) - kbPt
    let line = String(format: "%.5f,%d,%d,%d,%.3f,%.2f,%.2f,%.2f,%@", pts, counter, composerTop, kbTop, scale, ctPt, kbPt, residual, status)

    // optional frame dump
    var saveName: String?
    if var r = req {
      lock.lock()
      let n = (savedCount[r.0] ?? 0)
      if n < r.1 { savedCount[r.0] = n + 1; saveName = "\(r.0)_\(n)_c\(counter)" } else { saveRequests.removeFirst(); r.1 = 0 }
      lock.unlock()
      req = r
    }
    lock.lock(); rows.append(line); lock.unlock()
    if let saveName {
      let img = CIImage(cvPixelBuffer: pb)
      if let cg = ci.createCGImage(img, from: img.extent), let data = UIImage(cgImage: cg).pngData() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("frames/\(saveName).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
      }
    }
  }
}
