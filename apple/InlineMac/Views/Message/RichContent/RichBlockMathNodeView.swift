import AppKit
import TextProcessing

final class RichBlockMathNodeView: RichBlockRenderableView {
  private let sourceSurface = RichBlockTextSurface(frame: .zero)
  private let scrollView = NSScrollView()
  private let imageView = NSImageView()
  private let progress = NSProgressIndicator()
  private var request: RichTextMath.Request?
  private var imageSize: CGSize?
  private var source = ""

  override var orderedTextSurfaces: [RichBlockTextSurface] {
    sourceSurface.isHidden ? [] : [sourceSurface]
  }

  init() {
    super.init(reuseKind: .math)
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScrollElasticity = .none
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = imageView
    imageView.imageScaling = .scaleNone
    imageView.imageAlignment = .alignLeft
    imageView.allowsCutCopyPaste = false
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    addSubview(sourceSurface)
    addSubview(scrollView)
    addSubview(progress)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .math(math) = node.kind,
          math.range.location >= 0, math.range.length >= 0,
          math.range.location <= context.attributedText.length,
          math.range.length <= context.attributedText.length - math.range.location
    else { prepareForReuse(); return }
    source = (context.attributedText.string as NSString).substring(with: math.range)
    let next = RichTextMath.request(text: context.attributedText, range: math.range, fontSize: context.baseFontSize)
    if request != next {
      imageView.image = nil
      scrollView.contentView.scroll(to: .zero)
    }
    request = next
    imageSize = math.imageSize
    if let image = context.math.image(for: math.range) {
      imageView.image = NSImage(cgImage: image.image, size: CGSize(width: image.width, height: image.height))
    }
    let rendered = math.imageSize != nil
    if !rendered { imageView.image = nil }
    sourceSurface.isHidden = rendered
    scrollView.isHidden = !rendered
    if rendered, imageView.image == nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    if !rendered {
      sourceSurface.apply(
        text: context.text(for: .init(rangeOffset: math.range.location, rangeLength: math.range.length,
                                     role: .paragraph, literal: nil, isRTL: false)),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    }
    setAccessibilityElement(rendered)
    if rendered {
      setAccessibilityRole(.image)
      setAccessibilityLabel("Formula: \(source)")
      setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Copy LaTeX", target: self, selector: #selector(copySource))])
    } else {
      setAccessibilityLabel(nil)
      setAccessibilityCustomActions(nil)
    }
    toolTip = source
    needsLayout = true
  }

  override func layout() {
    super.layout()
    sourceSurface.frame = bounds
    scrollView.frame = bounds
    imageView.frame = CGRect(origin: .zero, size: CGSize(width: max(bounds.width, imageSize?.width ?? 0), height: bounds.height))
    progress.frame = CGRect(x: 4, y: max(0, (bounds.height - 16) / 2), width: 16, height: 16)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Copy LaTeX", action: #selector(copySource), keyEquivalent: "")
    item.target = self
    menu.insertItem(item, at: 0)
    return menu
  }

  @objc private func copySource() -> Bool {
    guard !source.isEmpty else { return false }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(source, forType: .string)
    return true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    progress.stopAnimation(nil)
    imageView.image = nil
    request = nil
    imageSize = nil
    source = ""
    sourceSurface.isHidden = true
    scrollView.isHidden = true
    toolTip = nil
    setAccessibilityElement(false)
    setAccessibilityLabel(nil)
    setAccessibilityCustomActions(nil)
  }
}
