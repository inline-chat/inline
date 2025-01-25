import Darwin
import SwiftUI

struct SystemMetricsView: View {
  @StateObject private var monitor = SystemMonitor()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MetricRow(title: "Memory", value: monitor.memoryUsage, unit: " MB").offset(y: 1)
      MetricRow(title: "CPU", value: monitor.cpuUsage, unit: "%").offset(y: -1)
    }
    .frame(width: 120, height: Theme.devtoolsHeight - 4)
    .padding(.horizontal, 1)
    .onAppear {
      monitor.startMonitoring()
    }
    .onDisappear {
      monitor.stopMonitoring()
    }
  }
}

struct MetricRow: View {
  let title: String
  let value: String
  let unit: String

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .foregroundStyle(.secondary)
        .font(.caption)
      Spacer()
      Text(value)
        .contentTransition(.numericText())
        .font(.caption)
        .monospacedDigit()
      Text("\(unit)")
        .font(.caption)
        .monospacedDigit()
    }
  }
}

final class SystemMonitor: ObservableObject {
  @Published private(set) var memoryUsage = "0"
  @Published private(set) var cpuUsage = "0"

  private var timer: Timer?

  func startMonitoring() {
    stopMonitoring()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.updateMetrics()
    }
  }

  func stopMonitoring() {
    timer?.invalidate()
    timer = nil
  }

  deinit {
    stopMonitoring()
  }

  private func updateMetrics() {
    Task { [weak self] in
      guard let self else { return }

      let memoryUsage = formatMemoryUsage(getMemoryUsage())
      let cpuUsage = formatCPUUsage(getCPUUsage())

      DispatchQueue.main.async {
        withAnimation(.default.speed(2)) {
          self.memoryUsage = memoryUsage
        }
      }

      // delay so animation looks good
      try await Task.sleep(for: .seconds(0.1))

      DispatchQueue.main.async {
        withAnimation(.default.speed(2)) {
          self.cpuUsage = cpuUsage
        }
      }
    }
  }

  private func getMemoryUsage() -> UInt64 {
    var taskInfo = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &taskInfo) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }

    guard result == KERN_SUCCESS else { return 0 }
    return taskInfo.phys_footprint
  }

  private func getCPUUsage() -> Double {
    var totalUsageOfCPU = 0.0
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0

    let threadResult = task_threads(mach_task_self_, &threadList, &threadCount)

    if threadResult == KERN_SUCCESS, let threadList {
      for index in 0 ..< threadCount {
        var threadInfo = thread_basic_info()
        var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

        let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
          $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            thread_info(
              threadList[Int(index)],
              thread_flavor_t(THREAD_BASIC_INFO),
              $0,
              &threadInfoCount
            )
          }
        }

        if infoResult == KERN_SUCCESS {
          let cpuUsage = Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)
          totalUsageOfCPU += cpuUsage
        }
      }

      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threadList)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
      )
    }

    return totalUsageOfCPU * 100
  }

  private func formatMemoryUsage(_ usage: UInt64) -> String {
    let megabytes = Double(usage) / 1_024 / 1_024
    return String(format: "%.1f", megabytes)
  }

  private func formatCPUUsage(_ usage: Double) -> String {
    String(format: "%.1f", usage)
  }
}
