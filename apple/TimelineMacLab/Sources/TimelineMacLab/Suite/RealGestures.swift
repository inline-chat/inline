import Foundation

/// Real trackpad gestures from a Dev build's log (2026-11-26): the finger events before the lift, the first momentum
/// events, the whole stream's travel, and NSScrollView's measured travel for each (the NSScrollView lane replayed them
/// with their full streams; NSScrollView ignores the momentum deltas and runs AppKit's calculator from its own reading
/// of the fingers' speed). Deltas and timings only.
struct RealGesture {
  var name: String
  /// [seconds before the lift, delta], oldest first.
  var tracked: [[Double]]
  var momentumDelay: Double
  /// [seconds after the first momentum event, delta].
  var momentum: [[Double]]
  var trackedTravel: Double
  var momentumTravel: Double
  /// NSScrollView's travel with the fingers' (NSScrollView lane, median of 3 replays, rows 1 ms).
  var nsScrollViewTravel: Double

  static let all: [RealGesture] = [
    RealGesture(
      name: "#17 1140 pt/s",
      tracked: [[0.8351, 1.0], [0.8176, 1.0], [0.8009, 3.0], [0.7844, 4.0], [0.7675, 4.0], [0.7510, 5.0], [0.7340, 5.0], [0.7176, 6.0], [0.7017, 7.0], [0.6838, 9.0], [0.6676, 9.0], [0.6510, 9.0], [0.6351, 11.0], [0.6176, 14.0], [0.6007, 19.0], [0.5843, 22.0], [0.5677, 28.0], [0.5505, 28.0], [0.5340, 23.0], [0.5183, 17.0], [0.5007, 11.0], [0.4846, 9.0], [0.4675, 5.0], [0.4518, 3.0], [0.4351, 1.0], [0.4184, 1.0], [0.4018, 1.0], [0.3841, 1.0], [0.3517, 1.0], [0.3341, 1.0], [0.3017, 1.0], [0.2844, 1.0], [0.2674, 0.0], [0.2517, 0.0], [0.2351, 0.0], [0.2184, 0.0], [0.1851, 1.0], [0.1612, 1.0], [0.1517, 1.0], [0.1289, 5.0], [0.1153, 16.0], [0.1017, 34.0], [0.0829, 40.0], [0.0684, 36.0], [0.0503, 21.0], [0.0335, 14.0], [0.0169, 15.0], [0.0001, 8.0]],
      momentumDelay: 0.0067,
      momentum: [[0.0000, 19.0], [0.0158, 22.0], [0.0334, 23.0], [0.0500, 23.0], [0.0667, 22.0], [0.0834, 22.0], [0.1000, 25.0], [0.1165, 24.0]],
      trackedTravel: 453.0, momentumTravel: 324.0, nsScrollViewTravel: 602.0
    ),
    RealGesture(
      name: "#44 1800 pt/s",
      tracked: [[0.0892, -1.0], [0.0653, -4.0], [0.0515, -12.0], [0.0353, -19.0], [0.0183, -26.0], [0.0002, -17.0]],
      momentumDelay: 0.0100,
      momentum: [[0.0000, -30.0], [0.0231, -33.0], [0.0345, -34.0], [0.0550, -34.0], [0.0700, -34.0], [0.0856, -33.0], [0.1002, -36.0], [0.1194, -35.0]],
      trackedTravel: -79.0, momentumTravel: -638.0, nsScrollViewTravel: -192.0
    ),
    RealGesture(
      name: "#66 20280 pt/s",
      tracked: [[0.0506, -12.0], [0.0505, -5.0], [0.0320, -60.0], [0.0151, -180.0], [0.0001, -318.0]],
      momentumDelay: 0.0042,
      momentum: [[0.0000, -338.0], [0.0173, -310.0], [0.0347, -286.0], [0.0502, -267.0], [0.0667, -251.0], [0.0839, -235.0], [0.1010, -209.0], [0.1164, -197.0]],
      trackedTravel: -575.0, momentumTravel: -5664.0, nsScrollViewTravel: -5274.0
    ),
    RealGesture(
      name: "#69 13380 pt/s",
      tracked: [[0.0841, -5.0], [0.0669, -12.0], [0.0502, -44.0], [0.0343, -134.0], [0.0176, -178.0]],
      momentumDelay: 0.0001,
      momentum: [[0.0000, -223.0], [0.0162, -227.0], [0.0332, -215.0], [0.0496, -203.0], [0.0659, -192.0], [0.0832, -181.0], [0.0983, -162.0], [0.1159, -153.0]],
      trackedTravel: -373.0, momentumTravel: -4003.0, nsScrollViewTravel: -1430.0
    ),
  ]
}
