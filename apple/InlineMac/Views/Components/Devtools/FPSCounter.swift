import AppKit
import Charts
import CoreVideo
import SwiftUI

struct FPSMeasurement: Identifiable, Equatable {
  let id: Int
//  let date: Date
  let fps: Int

  static func == (lhs: FPSMeasurement, rhs: FPSMeasurement) -> Bool {
    lhs.id == rhs.id
  }
}

class FPSHistory: ObservableObject {
  @Published var history: [FPSMeasurement] = []
}

@available(macOS 14.0, *)
class FPSCounter: ObservableObject {
  @Published private(set) var fps = 0
  private(set) var fpsHistory = FPSHistory()

  private var displayLink: CADisplayLink?
  static let maxHistoryCount = 20
  let maxHistoryCount = FPSCounter.maxHistoryCount
  private(set) var nextId = 100

  private var frameCount = 0
  private var lastTimestamp: CFTimeInterval = 0
  private let updateInterval: CFTimeInterval = 0.2 // Changed from 0.5 to 0.1 for more frequent updates
  private var isTracking = false
  private weak var trackedWindow: NSWindow?

  private func fillHistory() {
    for index in 0 ... maxHistoryCount {
      fpsHistory.history
        .append(
          FPSMeasurement(
            id: index,
            fps: maxFPS
          )
        )
    }
  }

  func pause() {
    displayLink?.remove(from: .main, forMode: .common)
    fpsHistory.history.removeAll()
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

    displayLink = window.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
    displayLink?.add(to: .main, forMode: .common)
  }

  func stopTracking() {
    displayLink?.invalidate()
    displayLink = nil
    trackedWindow = nil
    isTracking = false
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

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        fps = currentFPS // Remove the min(maxFPS) constraint

        withAnimation(.linear(duration: 0.195)) {
          if self.fpsHistory.history.isEmpty {
            self.fillHistory()
            return
          }

          self.fpsHistory.history.append(FPSMeasurement(id: self.nextId, fps: self.fps))
          if self.fpsHistory.history.count > self.maxHistoryCount {
            self.fpsHistory.history.removeFirst()
          }
        }

        nextId += 1
      }

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
struct ChartView: View {
  let paused: Bool
  @ObservedObject var fps: FPSHistory
  let maxFPS: Int

  let barWidth: CGFloat
  let barSpacing: CGFloat
  var chartWidth: CGFloat

  var body: some View {
    Group {
      if fps.history.isEmpty || paused {
        pausedView
      } else {
        HStack(alignment: .bottom, spacing: barSpacing) {
          ForEach(fps.history) { measurement in
            FPSBar(
              fps: measurement.fps,
              maxFPS: maxFPS,
              width: barWidth
            ).equatable()
          }
        }
        .frame(width: chartWidth, height: Theme.devtoolsHeight - 4)
        .contentShape(.interaction, .rect)
        .padding(.horizontal, 0)
        .cornerRadius(6)
      }
    }
    .animation(.easeOut(duration: 0.2), value: fps.history.isEmpty)
    .animation(.easeOut(duration: 0.2), value: paused)
  }

  @ViewBuilder
  var pausedView: some View {
    Rectangle()
      .cornerRadius(6)
      .foregroundStyle(.gray.gradient.quaternary)
      .overlay(content: {
        if paused {
          Text("Paused")
            .font(.caption)
            .foregroundColor(.gray)
        }
      })
      .frame(width: chartWidth, height: Theme.devtoolsHeight - 4)
  }
}

@available(macOS 14.0, *)
struct FPSView: View {
  @StateObject private var counter = FPSCounter()
  @State private var isStressing = false
  @State private var heavyWorkItems: [Int] = []
  @State private var paused = false
  @State private var hasChart = true

  @ViewBuilder
  var texts: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text("\(counter.fps) FPS")
        .foregroundColor(.blue)
        .font(.system(size: 12, weight: .semibold))
        .offset(y: 2).fixedSize()
//        .animation(.easeOut(duration: 0.08), value: counter.fps)
      Text("\(counter.maxFPS)Hz")
        .foregroundColor(.gray)
        .font(.caption)
        .offset(y: -1)
    }
    .frame(
      width: 47,
      alignment: .trailing
    ) // to not change width when changes
    .padding(.trailing, 4)
  }

  let barWidth: CGFloat = 2
  let barSpacing: CGFloat = 2
  var chartWidth: CGFloat {
    (barWidth + barSpacing) * CGFloat(FPSCounter.maxHistoryCount)
  }

  var chart: some View {
    ChartView(
      paused: paused,
      fps: counter.fpsHistory,
      maxFPS: counter.maxFPS,
      barWidth: barWidth,
      barSpacing: barSpacing,
      chartWidth: chartWidth
    )
    .shakeEffect(isShaking: isStressing)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      texts

      if hasChart {
        chart
      }
    }
    .onTapGesture {
      togglePaused()
    }
    .animation(.easeOut(duration: 0.2), value: hasChart)
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
      }

      Button(paused ? "Resume" : "Pause") {
        togglePaused()
      }

      Button(!hasChart ? "Enable Chart View" : "Disable Chart View") {
        hasChart.toggle()
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

        for _ in 0 ... 10_000 {
          heavyWorkItems.append(Int.random(in: 0 ... 1_000))
          _ = sqrt(Double.random(in: 0 ... 10_000))
        }
        heavyWorkItems.removeAll()
      }
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
      .offset(
        x: isShaking ? CGFloat(Int.random(in: -3 ... 3)) : 0,
        y: isShaking ? CGFloat(Int.random(in: -1 ... 1)) : 0
      )
      .animation(
        isShaking ?
          .easeIn(duration: 0.09).repeatForever(autoreverses: true) :
          .default,
        value: isShaking
      )
  }
}

@available(macOS 14.0, *)
struct FPSBar: View, Equatable {
  let fps: Int
  let maxFPS: Int
  let width: CGFloat

  private let maxHeight: CGFloat = Theme.devtoolsHeight - 4

  private var heightPercentage: CGFloat {
    guard maxFPS > 0 else { return 0 }
    return CGFloat(fps) / CGFloat(maxFPS)
  }

  var p: Double {
    Double(fps) / Double(maxFPS)
  }

  @ViewBuilder
  var shape: some View {
    if p > 0.75 {
      RoundedRectangle(cornerRadius: 1.0)
        .fill(.blue.gradient)
    } else if p > 0.5 {
      RoundedRectangle(cornerRadius: 1.0)
        .fill(.blue.gradient.secondary)
    } else {
      RoundedRectangle(cornerRadius: 1.0)
        .fill(.blue.gradient.tertiary)
    }
  }

  var body: some View {
    shape
      .frame(width: width, height: maxHeight * heightPercentage)
      .frame(maxHeight: maxHeight, alignment: .bottom)
  }
}
