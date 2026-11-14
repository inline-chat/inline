import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    if let items = try? FileManager.default.contentsOfDirectory(at: Lab.docs, includingPropertiesForKeys: nil) {
      for u in items { try? FileManager.default.removeItem(at: u) }
    }
    Lab.log("launch args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))")
    return true
  }

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = RootHostingController(rootView: RootView())
    window.backgroundColor = .black
    self.window = window
    window.makeKeyAndVisible()
  }

  func sceneDidEnterBackground(_ scene: UIScene) { Lab.log("scene didEnterBackground"); LabHub.shared.onBackground?() }
  func sceneWillEnterForeground(_ scene: UIScene) { Lab.log("scene willEnterForeground"); LabHub.shared.onForeground?() }
}

/// Hosting controller that reports rotation callbacks to the lab (the lab view is a UIViewRepresentable).
final class RootHostingController: UIHostingController<RootView> {
  override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
    LabHub.shared.willTransition?(size, coordinator)
    super.viewWillTransition(to: size, with: coordinator)
  }
}

/// Small bridge so UIKit-side code (rotation, scene lifecycle) can reach the live lab view.
@MainActor
final class LabHub {
  static let shared = LabHub()
  var willTransition: ((CGSize, any UIViewControllerTransitionCoordinator) -> Void)?
  var onBackground: (() -> Void)?
  var onForeground: (() -> Void)?
}

struct RootView: View {
  @State private var path: [String] = Lab.autopush ? ["lab"] : []
  @State private var mode: String = Lab.mode

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section("Lab mode") {
          Picker("Mode", selection: $mode) {
            ForEach(Lab.allModes, id: \.self) { Text(Lab.modeTitle($0)).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .accessibilityIdentifier("modePicker")
        }
        Section {
          Button("Open lab") {
            Lab.mode = mode
            path = ["lab"]
          }
          .accessibilityIdentifier("openLab")
        }
        Section("Notes") {
          Text("Lab screen: drag content to scroll (S3 engines), tap the bar to type. Top-right chip in the lab switches the S3 engine. Launch args: -mode <id> -autorun 1.")
            .font(.footnote)
        }
      }
      .navigationTitle("TimelineLab")
      .navigationDestination(for: String.self) { _ in
        Group {
          if Lab.mode == "E1" { EngineScreen() } else { LabScreen() }
        }
          .ignoresSafeArea(.container, edges: .bottom)
          .ignoresSafeArea(.keyboard)
          .navigationTitle(Lab.modeTitle(Lab.mode))
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}

struct LabScreen: UIViewRepresentable {
  func makeUIView(context: Context) -> LabView { LabView(mode: Lab.mode) }
  func updateUIView(_ uiView: LabView, context: Context) {}
}
