import AppKit
import InlineContextMenu

/// Opens a real native context menu and, while it tracks, dumps its windows, views and layers, so the
/// custom engine can match its material, metrics and colors from facts instead of screenshots.
/// `--dump-native [out.txt]`.
@MainActor
enum NativeMenuDump {
  static func run(controller: LabWindowController, out: String?, shotDir: String?) {
    controller.setMode(.native)
    if CommandLine.arguments.contains("--dark") { controller.window.appearance = NSAppearance(named: .darkAqua) }
    guard let bubble = controller.bubbles.first as? BubbleView, let window = bubble.window else { return }
    let point = bubble.convert(NSPoint(x: 30, y: bubble.bounds.midY), to: nil)
    guard let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ), let menu = controller.lab.menu(for: bubble, event: event, nativeTextMenu: nil) else { return }

    var text = ""
    let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
      MainActor.assumeIsolated {
        for win in NSApp.windows where win.isVisible && win !== window {
          text += windowFlags(win)
          text += "WINDOW \(type(of: win)) frame=\(win.frame) level=\(win.level.rawValue) opaque=\(win.isOpaque) bg=\(win.backgroundColor.debugDescription) alpha=\(win.alphaValue) shadow=\(win.hasShadow) appearance=\(win.effectiveAppearance.name.rawValue) id=\(win.windowNumber)\n"
          if let content = win.contentView?.superview ?? win.contentView {
            dumpView(content, depth: 1, into: &text)
          }
          if let shotDir {
            let path = (shotDir as NSString).appendingPathComponent("native-window-\(win.windowNumber).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(win.windowNumber)", path]
            try? process.run()
            process.waitUntilExit()
            text += "SHOT \(path)\n"
          }
        }
        menu.cancelTracking()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSMenu.popUpContextMenu(menu, with: event, for: bubble)

    // Our own panel, same bubble, for a side-by-side of the layer trees.
    controller.setMode(.custom)
    _ = controller.lab.menu(for: bubble, event: event, nativeTextMenu: nil)
    let spin = Date().addingTimeInterval(0.6)
    while Date() < spin { RunLoop.main.run(mode: .default, before: spin) }
    for win in NSApp.windows where win.isVisible && win !== window {
      text += windowFlags(win)
      text += "CUSTOM WINDOW \(type(of: win)) frame=\(win.frame) level=\(win.level.rawValue) shadow=\(win.hasShadow)\n"
      if let content = win.contentView { dumpView(content, depth: 1, into: &text) }
    }
    ContextMenuSession.closeAll()

    text += "\nNSGlassEffectView methods:\n"
    if #available(macOS 26.0, *) {
      for cls: AnyClass in [NSGlassEffectView.self, NSClassFromString("NSPopupMenuWindow"), NSClassFromString("NSGlassEffectWindow")].compactMap({ $0 }) {
        var count: UInt32 = 0
        if let list = class_copyMethodList(cls, &count) {
          let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
          let interesting = names.filter { $0.lowercased().contains("variant") || $0.lowercased().contains("glass") || $0.lowercased().contains("material") || $0.lowercased().contains("subdued") || $0.lowercased().contains("adaptive") || $0.lowercased().contains("style") }
          text += "\(cls): \(interesting.sorted().joined(separator: " "))\n"
          free(list)
        }
      }
    }

    if let out {
      try? text.write(toFile: out, atomically: true, encoding: .utf8)
    } else {
      print(text)
    }
    NSApp.terminate(nil)
  }

  private static func windowFlags(_ win: NSWindow) -> String {
    var line = "FLAGS \(type(of: win)) key=\(win.isKeyWindow) main=\(win.isMainWindow) canKey=\(win.canBecomeKey)"
    for key in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "hasKeyAppearance", "hasMainAppearance", "_hasKeyAppearance", "_hasMainAppearance", "_isNonactivatingPanel"] {
      if win.responds(to: NSSelectorFromString(key)) { line += " \(key)=\(String(describing: win.value(forKey: key) ?? "nil"))" }
    }
    var cls: AnyClass? = object_getClass(win)
    var names: [String] = []
    while let current = cls, current != NSResponder.self {
      var count: UInt32 = 0
      if let list = class_copyMethodList(current, &count) {
        let interesting = (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.filter { let l = $0.lowercased(); return l.contains("activeappearance") || l.contains("keyappearance") || l.contains("glass") }
        if !interesting.isEmpty { names.append("\(current): \(interesting.sorted().joined(separator: " "))") }
        free(list)
      }
      cls = class_getSuperclass(current)
    }
    return line + "\n  " + names.joined(separator: "\n  ") + "\n"
  }

  private static func dumpView(_ view: NSView, depth: Int, into text: inout String) {
    guard depth < 14 else { return }
    let pad = String(repeating: "  ", count: depth)
    var line = "\(pad)\(type(of: view)) frame=\(fmt(view.frame))"
    if view.isHidden { line += " HIDDEN" }
    if view.alphaValue != 1 { line += " alpha=\(view.alphaValue)" }
    if let effect = view as? NSVisualEffectView {
      line += " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue) state=\(effect.state.rawValue) emphasized=\(effect.isEmphasized)"
    }
    if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
      line += " glassStyle=\(glass.style.rawValue) tint=\(glass.tintColor?.debugDescription ?? "nil") radius=\(glass.cornerRadius)"
      for key in ["_variant", "_subvariant", "_subduedState", "_adaptiveAppearance", "_placesContentAboveGlass", "_vibrantBlendingStyleForSubtree", "_scrollPocketElementStyle", "_effectInteractiveVariantName"] {
        if glass.responds(to: NSSelectorFromString(key)) {
          line += " \(key)=\(String(describing: glass.value(forKey: key) ?? "nil"))"
        }
      }
    }
    if let image = view as? NSImageView {
      line += " image=\(fmt(image.image?.size ?? .zero)) tint=\(image.contentTintColor?.debugDescription ?? "nil") symbolConfig=\(image.symbolConfiguration?.debugDescription ?? "nil") enabled=\(image.isEnabled)"
    }
    if let field = view as? NSTextField {
      line += " text=\"\(field.stringValue)\" font=\(field.font?.fontName ?? "-") \(field.font?.pointSize ?? 0) color=\(field.textColor?.debugDescription ?? "nil") enabled=\(field.isEnabled)"
      if field.attributedStringValue.length > 0 {
        let attrs = field.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        if let color = attrs[.foregroundColor] { line += " attrColor=\(color)" }
        if let font = attrs[.font] as? NSFont { line += " attrFont=\(font.fontName) \(font.pointSize)" }
      }
    }
    if let layer = view.layer {
      line += " layer=\(type(of: layer))"
      line += layerProps(layer)
    }
    text += line + "\n"
    if let layer = view.layer {
      dumpSublayers(of: layer, owned: Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) }), depth: depth + 1, into: &text)
    }
    for sub in view.subviews {
      dumpView(sub, depth: depth + 1, into: &text)
    }
  }

  private static func dumpSublayers(of layer: CALayer, owned: Set<ObjectIdentifier>, depth: Int, into text: inout String) {
    guard depth < 16 else { return }
    for sub in layer.sublayers ?? [] where !owned.contains(ObjectIdentifier(sub)) {
      let pad = String(repeating: "  ", count: depth)
      text += "\(pad)· \(type(of: sub)) frame=\(fmt(sub.frame))\(layerProps(sub))\n"
      dumpSublayers(of: sub, owned: [], depth: depth + 1, into: &text)
    }
  }

  private static func layerProps(_ layer: CALayer) -> String {
    var s = ""
    if let bg = layer.backgroundColor { s += " bg=\(describe(bg))" }
    if layer.opacity != 1 { s += " opacity=\(layer.opacity)" }
    if layer.cornerRadius != 0 { s += " radius=\(layer.cornerRadius)" }
    if layer.borderWidth != 0 { s += " border=\(layer.borderWidth) \(layer.borderColor.map(describe) ?? "")" }
    if let filters = layer.filters, !filters.isEmpty { s += " filters=\(filters.map { "\($0)" })" }
    if let filter = layer.compositingFilter { s += " compositing=\(filter)" }
    if let filters = layer.backgroundFilters, !filters.isEmpty { s += " bgFilters=\(filters.map { "\($0)" })" }
    if layer.shadowOpacity > 0 { s += " shadow=\(layer.shadowOpacity)/\(layer.shadowRadius)/\(layer.shadowOffset)" }
    if layer.contents != nil { s += " contents" }
    if layer.mask != nil { s += " mask" }
    if let name = layer.name { s += " name=\(name)" }
    return s
  }

  private static func describe(_ color: CGColor) -> String {
    let comps = (color.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
    return "\(color.colorSpace?.name.map { $0 as String } ?? "?")(\(comps))"
  }

  private static func fmt(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.minX, rect.minY, rect.width, rect.height)
  }

  private static func fmt(_ size: NSSize) -> String {
    String(format: "%.1fx%.1f", size.width, size.height)
  }
}
