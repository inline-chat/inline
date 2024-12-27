import AppKit
import Charts
import CoreVideo
import SwiftUI

struct FPSMeasurement: Identifiable, Equatable {
  let id: Int
  let date: Date
  let fps: Int
  
  static func == (lhs: FPSMeasurement, rhs: FPSMeasurement) -> Bool {
    lhs.id == rhs.id
  }
}

@available(macOS 14.0, *)
class FPSCounter: ObservableObject {
  @Published private(set) var fps = 0
  @Published private(set) var fpsHistory: [FPSMeasurement] = []
  
  private var displayLink: CADisplayLink?
  private let maxHistoryCount = 30
  private(set) var nextId = 100
  
  private var frameCount = 0
  private var lastTimestamp: CFTimeInterval = 0
  private let updateInterval: CFTimeInterval = 0.2 // Changed from 0.5 to 0.1 for more frequent updates
  private var isTracking = false
  private weak var trackedWindow: NSWindow?
  
  private func fillHistory() {
    for index in 0...30 {
      fpsHistory
        .append(
          FPSMeasurement(
            id: index,
            date: Date(
              timeIntervalSince1970: Date().timeIntervalSince1970 - Double(
                30 - index
              ) * 0.2
            ),
            fps: maxFPS
          )
        )
    }
  }

  func pause() {
    displayLink?.remove(from: .main, forMode: .common)
    fpsHistory.removeAll()
  }

  func resume() {
    displayLink?.add(to: .main, forMode: .common)
  }

  func startTracking(in window: NSWindow) {
    if isTracking {
      return
    }
    
    isTracking = true
    
    trackedWindow = window
    
    print("Tracking started")
    displayLink = window.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
    displayLink?.add(to: .main, forMode: .common)
  }
  
  func stopTracking() {
    displayLink?.invalidate()
    displayLink = nil
    trackedWindow = nil
  }
  
  deinit {
    stopTracking()
  }
  
  @objc private func displayLinkDidFire(_ link: CADisplayLink) {
    if lastTimestamp == 0 {
      lastTimestamp = link.timestamp
      return
    }
    
    frameCount += 1
    
    let elapsed = link.timestamp - lastTimestamp
    if elapsed >= updateInterval {
      let currentFPS = Int(round(Double(frameCount) / elapsed))
      
//      DispatchQueue.main.async { [weak self] in
//        guard let self else { return }
      fps = currentFPS // Remove the min(maxFPS) constraint
        
      if fpsHistory.isEmpty {
        fillHistory()
      }
        
      fpsHistory.append(FPSMeasurement(id: nextId, date: Date(), fps: fps))
      nextId += 1
      if fpsHistory.count > maxHistoryCount {
        fpsHistory.removeFirst()
      }
//      }
      
      frameCount = 0
      lastTimestamp = link.timestamp
    }
  }
  
  var maxFPS: Int {
    guard let screen = trackedWindow?.screen else { return 60 }
    // Convert refresh interval to frequency
    return Int(round(1.0 / screen.maximumRefreshInterval))
  }
}

@available(macOS 14.0, *)
struct FPSView: View {
  @StateObject private var counter = FPSCounter()
  @State private var isStressing = false
  @State private var heavyWorkItems: [Int] = []
  @State private var paused = false
  
  @ViewBuilder
  var texts: some View {
    VStack(alignment: .trailing, spacing: 0) {
      HStack(spacing: 0) {
        Text("\(counter.fps)")
          .contentTransition(.numericText(value: Double(counter.fps)))
        Text(" FPS")
      }
      .animation(.default.speed(2.8), value: counter.fps)
      .font(.footnote)
      .offset(y: 1)
      
      Text("\(counter.maxFPS)Hz")
        .foregroundColor(.gray)
        .font(.caption)
        .offset(y: -1)
    }
    .frame(
      width: 36,
      alignment: .trailing
    ) // to not change width when changes
    .padding(.trailing, 4)
  }
  
  @ViewBuilder
  var pausedView: some View {
    Rectangle()
      .cornerRadius(8)
      .overlay(content: {
        if paused {
          Text("Paused")
            .font(.caption)
            .foregroundColor(.gray)
        }
      })
      .foregroundStyle(.gray.gradient.quaternary)
      .frame(width: 90, height: Theme.devtoolsHeight - 4)
  }
    
  var chart: some View {
//    Chart(counter.fpsHistory) {
//      BarMark(
//        x: .value("Time", $0.date),
//        y: .value("FPS", $0.fps),
//        width: 2.0
//      )
    ////      .foregroundStyle(getFpsColor(fps: $0.fps))
//    }
//    .chartXAxis(.hidden)
//    .chartYAxis(.hidden)
//    .chartYScale(domain: 0...counter.maxFPS)
    HStack(alignment: .bottom, spacing: 1) {
      ForEach(counter.fpsHistory) { measurement in
        FPSBar(
          fps: measurement.fps,
          maxFPS: counter.maxFPS,
          width: 2
        )
      }
    }
    .frame(width: 90, height: Theme.devtoolsHeight - 4)
    .contentShape(.interaction, .rect)
    .padding(.horizontal, 0)
    .cornerRadius(8)
    .shakeEffect(isShaking: isStressing)
    .animation(.linear(duration: 0.3), value: counter.fpsHistory)
  }
  
  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      texts
      
      if counter.fpsHistory.isEmpty || paused {
        pausedView
      } else {
        chart
      }
    }
    .onTapGesture {
      togglePaused()
    }
    .animation(.easeOut(duration: 0.2), value: counter.fpsHistory.isEmpty)
    .animation(.default, value: isStressing)
    .introspect(.window, on: .macOS(.v13, .v14, .v15)) { w in
      
      counter.startTracking(in: w)
    }
    .onAppear {
      paused = false
    }
    .padding(.horizontal, 4.0)
    .onDisappear {
      counter.stopTracking()
    }
    .contextMenu {
      Button(!isStressing ? "Enable Stress Test" : "Disable Stress Test") {
        toggleStressTest()
      }.id(isStressing ? 1 : 0)
      
      Button(paused ? "Resume" : "Pause") {
        togglePaused()
      }
    }
  }
  
  private func togglePaused() {
    let nextPaused = !paused
    paused.toggle()
    
    if nextPaused {
      counter.pause()
    } else {
      counter.resume()
    }
  }
    
  private func toggleStressTest() {
    let nextIsStressing = !isStressing
    isStressing.toggle()
   
    if nextIsStressing {
      Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        if !isStressing {
          timer.invalidate()
          return
        }
          
        for _ in 0...10000 {
          heavyWorkItems.append(Int.random(in: 0...1000))
          _ = sqrt(Double.random(in: 0...10000))
        }
        heavyWorkItems.removeAll()
      }
    }
  }
  
  private func getFpsColor(fps: Int) -> Color {
    switch counter.fps {
    case _ where fps >= counter.maxFPS * 90 / 100:
      return .green
    case _ where fps >= counter.maxFPS * 60 / 100:
      return .yellow
    default:
      return .red
    }
  }
}

extension View {
  func shakeEffect(isShaking: Bool) -> some View {
    modifier(ShakeEffect(isShaking: isShaking))
  }
}

struct ShakeEffect: ViewModifier {
  let isShaking: Bool
  
  func body(content: Content) -> some View {
    content
      .offset(x: isShaking ? CGFloat(Int.random(in: -6...4)) : 0,
              y: isShaking ? CGFloat(Int.random(in: -2...2)) : 0)
      .animation(
        .easeInOut(duration: 0.05)
          .repeatForever(autoreverses: true),
        value: isShaking
      )
  }
}

struct FPSBar: View {
  let fps: Int
  let maxFPS: Int
  let width: CGFloat
  
  private let maxHeight: CGFloat = Theme.devtoolsHeight - 4
  
  private var heightPercentage: CGFloat {
    guard maxFPS > 0 else { return 0 }
    return CGFloat(fps) / CGFloat(maxFPS)
  }
  
  var body: some View {
    Rectangle()
      .fill(fpsColor)
      .frame(width: width, height: maxHeight * heightPercentage)
      .frame(maxHeight: maxHeight, alignment: .bottom)
      .cornerRadius(3)
  }
  
  private var fpsColor: Color {
    let percentage = Double(fps) / Double(maxFPS)
    switch percentage {
    case 0.9...:
      return .green
    case 0.6...:
      return .yellow
    default:
      return .red
    }
  }
}
