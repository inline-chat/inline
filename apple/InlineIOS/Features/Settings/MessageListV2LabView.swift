#if DEBUG || DEBUG_BUILD
import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineTheme
import SwiftUI
import UIKit

/// Explicit opt-in fixture surface. It cannot obtain a live peer, send messages, or observe a chat.
struct MessageListV2LabView: UIViewControllerRepresentable {
  func makeUIViewController(context _: Context) -> MessageListV2LabController {
    MessageListV2LabController()
  }

  func updateUIViewController(_: MessageListV2LabController, context _: Context) {}
}

private struct MessageListV2FixtureRow {
  let message: FullMessage
  let plan: UIMessageView2.PreparedListLayout
}

/// No self sizing, data access, renderer work, or scroll corrections in layout callbacks.
private final class MessageListV2FixtureLayout: UICollectionViewLayout {
  private(set) var geometry: MessageListGeometryV2?
  private var attributes: [UICollectionViewLayoutAttributes] = []

  func install(_ geometry: MessageListGeometryV2) {
    self.geometry = geometry
    attributes = geometry.rows.enumerated().map { index, row in
      let result = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
      result.frame = row.frame
      return result
    }
    invalidateLayout()
  }

  override var collectionViewContentSize: CGSize {
    geometry?.contentSize ?? .zero
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard let geometry else { return [] }
    return geometry.indices(intersecting: rect).map { attributes[$0] }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
    return attributes[indexPath.item]
  }

  override func shouldInvalidateLayout(forBoundsChange _: CGRect) -> Bool {
    false
  }
}

private final class MessageListV2FixtureCell: UICollectionViewCell {
  private(set) var rowID: Int64?
  private(set) var renderer: UIMessageView2?
  private(set) var hasValidPlan = false
  private let failureLabel = UILabel()
  private var environment: MessageListV2LabController.Environment?
  private var theme: IOSThemeSnapshot?
  /// Kept until the collection has finished installing final attributes, including offscreen reuse.
  var compensationY: CGFloat = 0

  func bind(
    _ row: MessageListV2FixtureRow,
    environment: MessageListV2LabController.Environment,
    theme: IOSThemeSnapshot,
    animated: Bool
  ) {
    clipsToBounds = false
    contentView.clipsToBounds = false
    let retained = rowID == row.message.id && self.environment == environment && self.theme == theme && renderer != nil
    if !retained {
      renderer?.cancelPendingGeometryTransitions()
      renderer?.removeFromSuperview()
      let next = UIMessageView2(
        fullMessage: row.message,
        spaceId: nil,
        displayMode: .normal,
        bubbleTailSide: row.message.message.out == true ? .trailing : .leading,
        maximumBubbleContentWidth: environment.renderWidth * MessageBubbleWidthPolicy.maximumWidthFraction,
        theme: theme,
        renderingMode: .fixtureDisplay
      )
      // Includes rich table/code and reaction descendants: fixtures never invoke production actions.
      next.isUserInteractionEnabled = false
      contentView.addSubview(next)
      environment.applyTraits(to: next)
      renderer = next
      rowID = row.message.id
      self.environment = environment
      self.theme = theme
    }
    renderer?.frame = CGRect(x: 12, y: 0, width: environment.renderWidth, height: row.plan.bubble.size.height)
    hasValidPlan = renderer?.installListLayout(row.plan, message: row.message, animated: animated && retained) == true
    renderer?.isHidden = !hasValidPlan
    if hasValidPlan {
      failureLabel.removeFromSuperview()
    } else {
      failureLabel.text = "Fixture plan rejected: check width, traits and snapshot."
      failureLabel.font = .systemFont(ofSize: 12)
      failureLabel.textColor = .systemRed
      failureLabel.numberOfLines = 2
      failureLabel.frame = CGRect(x: 12, y: 0, width: environment.renderWidth, height: row.plan.bubble.size.height)
      contentView.addSubview(failureLabel)
    }
  }

  override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
    super.apply(layoutAttributes)
    contentView.transform = CGAffineTransform(translationX: 0, y: compensationY)
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    layoutAttributes
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    renderer?.cancelPendingGeometryTransitions()
    renderer?.removeFromSuperview()
    renderer = nil
    hasValidPlan = false
    failureLabel.removeFromSuperview()
    rowID = nil
    environment = nil
    theme = nil
    compensationY = 0
    contentView.transform = .identity
  }
}

final class MessageListV2LabController: UIViewController, UICollectionViewDelegate {
  fileprivate struct Environment: Equatable {
    let width: CGFloat
    let style: UIUserInterfaceStyle
    let category: UIContentSizeCategory
    let direction: UITraitEnvironmentLayoutDirection
    let scale: CGFloat
    var renderWidth: CGFloat {
      max(1, width - 24)
    }

    @MainActor func applyTraits(to view: UIView) {
      // A dequeued cell need not have entered the window yet. Both preparation and display
      // use this captured environment instead of depending on attachment timing.
      view.traitOverrides.userInterfaceStyle = style
      view.traitOverrides.preferredContentSizeCategory = category
      view.traitOverrides.layoutDirection = direction
      view.traitOverrides.displayScale = scale
    }
  }

  private struct PreparedUpdate {
    let revision: UInt
    let environment: Environment
    let theme: IOSThemeSnapshot
    let rows: [MessageListV2FixtureRow]
    let preparationMS: Double
    let measuredCount: Int
  }

  /// Capture BEFORE content binding. Keeping actual view references lets surviving rich nodes
  /// retain their presentation; inserted/removed nodes remain owned by the renderer transition.
  private struct Presentation {
    let view: UIView
    let bounds: CGRect
    let center: CGPoint
    let transform: CGAffineTransform
    let alpha: CGFloat

    init(_ view: UIView) {
      self.view = view
      let layer = view.layer.presentation() ?? view.layer
      bounds = layer.bounds
      center = layer.position
      transform = CATransform3DGetAffineTransform(layer.transform)
      alpha = CGFloat(layer.opacity)
    }

    func restore(in root: UIView) {
      guard view.isDescendant(of: root) else { return }
      view.bounds = bounds
      view.center = center
      view.transform = transform
      view.alpha = alpha
    }
  }

  private let layout = MessageListV2FixtureLayout()
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private var dataSource: UICollectionViewDiffableDataSource<Int, Int64>!
  private let status = UILabel()
  private let measurementHost = UIView()
  private var messages = MessageListV2LabFixtures.messages()
  private var renderedRows: [Int64: MessageListV2FixtureRow] = [:]
  private var installedEnvironment: Environment?
  private var installedTheme: IOSThemeSnapshot?
  private var cache: [Int64: MessageListV2FixtureRow] = [:]
  private var cacheEnvironment: Environment?
  private var cacheTheme: IOSThemeSnapshot?
  private var lastViewport: CGSize = .zero
  private var requestedEnvironment: Environment?
  private var preparation: Task<Void, Never>?
  private var burst: Task<Void, Never>?
  private var requestedRevision: UInt = 0
  private var transitionRevision: UInt = 0
  private var animator: UIViewPropertyAnimator?
  private var installing = false
  private var pending: PreparedUpdate?
  private var oldScreenY: [Int64: CGFloat] = [:]
  private var targetOffset: CGFloat = 0
  private var resized = false
  private var bottomConstraint: NSLayoutConstraint!
  private var nextID: Int64 = 30_000

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Message List 2 Lab"
    view.backgroundColor = .systemBackground
    collection.backgroundColor = .systemBackground
    collection.contentInsetAdjustmentBehavior = .never
    collection.alwaysBounceVertical = true
    collection.delegate = self
    collection.register(MessageListV2FixtureCell.self, forCellWithReuseIdentifier: "fixture")
    collection.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collection)
    measurementHost.isHidden = true
    view.addSubview(measurementHost)

    dataSource = UICollectionViewDiffableDataSource<
      Int,
      Int64
    >(collectionView: collection) { [weak self] view, path, id in
      guard let self,
            let row = renderedRows[id], let environment = installedEnvironment, let theme = installedTheme,
            let cell = view.dequeueReusableCell(withReuseIdentifier: "fixture", for: path) as? MessageListV2FixtureCell
      else { return nil }
      cell.compensationY = compensation(for: id)
      cell.bind(row, environment: environment, theme: theme, animated: false)
      return cell
    }

    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.numberOfLines = 3
    status.text = "Experimental · synthetic messages only\nPreparing exact layouts…"
    status.accessibilityIdentifier = "message-list-v2-status"
    let controls = UIStackView(arrangedSubviews: [
      status,
      buttonRow([
        ("React", #selector(react)),
        ("Grow", #selector(grow)),
        ("Burst", #selector(runBurst)),
        ("Append", #selector(appendMessage)),
      ]),
      buttonRow([
        ("Prepend", #selector(prependMessages)),
        ("Delete", #selector(deleteMessage)),
        ("Bottom", #selector(goToBottom)),
        ("Resize", #selector(resizeViewport)),
      ]),
    ])
    controls.axis = .vertical
    controls.spacing = 4
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    bottomConstraint = collection.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
    NSLayoutConstraint.activate([
      controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      collection.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
      collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomConstraint,
    ])
    registerForTraitChanges([
      UITraitUserInterfaceStyle.self,
      UITraitPreferredContentSizeCategory.self,
      UITraitLayoutDirection.self,
      UITraitDisplayScale.self,
    ]) {
      (controller: MessageListV2LabController, _: UITraitCollection) in
      controller.requestPreparation()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard collection.bounds.size != lastViewport else { return }
    lastViewport = collection.bounds.size
    // Schedules preparation only. The collection layout itself never changes scrolling.
    requestPreparation()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    preparation?.cancel()
    burst?.cancel()
    requestedRevision &+= 1
    pending = nil
    stopAnimation()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if isViewLoaded { requestPreparation() }
  }

  private func buttonRow(_ actions: [(String, Selector)]) -> UIStackView {
    let row = UIStackView(arrangedSubviews: actions.map { title, action in
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.addTarget(self, action: action, for: .touchUpInside)
      return button
    })
    row.distribution = .fillEqually
    return row
  }

  private var environment: Environment {
    Environment(
      width: collection.bounds.width,
      style: traitCollection.userInterfaceStyle,
      category: traitCollection.preferredContentSizeCategory,
      direction: traitCollection.layoutDirection,
      scale: max(1, traitCollection.displayScale)
    )
  }

  private func requestPreparation() {
    guard collection.bounds.width > 24, collection.bounds.height > 0 else { return }
    preparation?.cancel()
    requestedRevision &+= 1
    pending = nil
    let revision = requestedRevision
    let environment = environment
    let theme = ThemeManager.shared.snapshot(variant: environment.style == .dark ? .dark : .light)
    requestedEnvironment = environment
    if cacheEnvironment != environment || cacheTheme != theme {
      cache.removeAll(keepingCapacity: true)
      cacheEnvironment = environment
      cacheTheme = theme
    }
    let messages = messages
    preparation = Task { @MainActor [weak self] in
      guard let self else { return }
      var rows: [MessageListV2FixtureRow] = []
      var preparationMS: Double = 0
      var measuredCount = 0
      for (index, message) in messages.enumerated() {
        guard !Task.isCancelled, requestedRevision == revision else { return }
        if let cached = cache[message.id], cached.message == message {
          rows.append(cached)
        } else {
          let start = CACurrentMediaTime()
          let renderer = UIMessageView2(
            fullMessage: message, spaceId: nil, displayMode: .normal,
            bubbleTailSide: message.message.out == true ? .trailing : .leading,
            maximumBubbleContentWidth: environment.renderWidth * MessageBubbleWidthPolicy.maximumWidthFraction,
            theme: theme, renderingMode: .fixtureMeasurement
          )
          // Inherit the same traits as visible cells before preparing UIKit-dependent leaves.
          measurementHost.addSubview(renderer)
          environment.applyTraits(to: renderer)
          let plan = renderer.prepareListLayout(width: environment.renderWidth)
          renderer.removeFromSuperview()
          guard let plan else {
            status.text = "Preparation failed for fixture \(message.id). Previous geometry retained."
            return
          }
          let row = MessageListV2FixtureRow(message: message, plan: plan)
          rows.append(row)
          cache[message.id] = row
          preparationMS += (CACurrentMediaTime() - start) * 1_000
          measuredCount += 1
        }
        // Main-actor UIKit work is bounded between yields; this is not an off-main measurement claim.
        if index.isMultiple(of: 4) { await Task.yield() }
      }
      guard !Task.isCancelled, requestedRevision == revision else { return }
      let ids = Set(messages.map(\.id))
      cache = cache.filter { ids.contains($0.key) }
      submit(PreparedUpdate(
        revision: revision,
        environment: environment,
        theme: theme,
        rows: rows,
        preparationMS: preparationMS,
        measuredCount: measuredCount
      ))
    }
  }

  private var userIsScrolling: Bool {
    collection.isTracking || collection.isDragging || collection.isDecelerating
  }

  private func submit(_ update: PreparedUpdate) {
    guard update.revision == requestedRevision, update.environment == requestedEnvironment else { return }
    guard !installing, !userIsScrolling else {
      pending = update // Only the latest complete plan waits; dragging wins over list motion.
      return
    }
    install(update)
  }

  private func install(_ update: PreparedUpdate) {
    let start = CACurrentMediaTime()
    let previous = layout.geometry
    let oldOffset = collection.contentOffset.y
    let anchor = previous?.anchor(at: oldOffset)
    let follow = previous?.isFollowingBottom(at: oldOffset) ?? true
    guard let geometry = MessageListGeometryV2(
      items: update.rows.map { .init(id: $0.message.id, height: $0.plan.bubble.size.height) },
      width: update.environment.width, viewportHeight: collection.bounds.height,
      displayScale: update.environment.scale
    ) else { return }
    targetOffset = follow ? geometry.maximumOffsetY
      : anchor.flatMap { anchor in previous.map { geometry.offset(preserving: anchor, from: $0) } }
      ?? geometry.clampedOffset(oldOffset)

    let cells = collection.visibleCells.compactMap { $0 as? MessageListV2FixtureCell }
    let capturedScreenY = Dictionary(uniqueKeysWithValues: cells.compactMap { cell -> (Int64, CGFloat)? in
      guard let id = cell.rowID else { return nil }
      let layer = cell.contentView.layer.presentation() ?? cell.contentView.layer
      let translatedY = layer.position.y - layer.bounds.height / 2
      return (id, cell.frame.minY + translatedY - oldOffset)
    })
    let presentations = cells.flatMap { cell -> [Presentation] in
      guard let renderer = cell.renderer else { return [] }
      return renderer.subviews.flatMap { descendants(of: $0) }.map(Presentation.init)
    }
    stopAnimation()
    oldScreenY = capturedScreenY
    let revision = transitionRevision
    installing = true
    let animate = previous != nil && installedEnvironment == update.environment
      && installedTheme == update.theme && !UIAccessibility.isReduceMotionEnabled
    if !animate { oldScreenY.removeAll(keepingCapacity: true) }
    installedEnvironment = update.environment
    installedTheme = update.theme
    renderedRows = Dictionary(uniqueKeysWithValues: update.rows.map { ($0.message.id, $0) })

    UIView.performWithoutAnimation {
      layout.install(geometry)
      for cell in cells {
        guard let id = cell.rowID, let row = renderedRows[id] else { continue }
        cell.compensationY = animate ? compensation(for: id) : 0
        cell.bind(row, environment: update.environment, theme: update.theme, animated: animate)
      }
      if animate { presentations.forEach { $0.restore(in: collection) } }
      var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
      snapshot.appendSections([0])
      snapshot.appendItems(update.rows.map(\.message.id))
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        // UIKit may complete synchronously. Start presentation only after the offset and final
        // attributes below have been installed, including the initial non-animated snapshot.
        DispatchQueue.main.async { [weak self] in
          self?.completeInstall(update, revision: revision, animate: animate, start: start)
        }
      }
      collection.layoutIfNeeded()
      collection.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
    }
  }

  private func completeInstall(_ update: PreparedUpdate, revision: UInt, animate: Bool, start: Double) {
    guard update.revision == requestedRevision, update.environment == requestedEnvironment else {
      installing = false
      drainPending()
      return
    }
    // A drag may have interrupted the asynchronous diffable completion. Do not move it back.
    let shouldAnimate = animate && revision == transitionRevision && !userIsScrolling
    collection.layoutIfNeeded()
    let cells = collection.visibleCells.compactMap { $0 as? MessageListV2FixtureCell }
    let renderers = cells.compactMap { cell -> (UIMessageView2, UIMessageView2.PreparedListLayout, UInt)? in
      guard cell.hasValidPlan, let id = cell.rowID,
            let row = renderedRows[id], let renderer = cell.renderer else { return nil }
      return (renderer, row.plan, renderer.geometryTransitionGeneration)
    }
    // Cell.apply may still be called during animation; only the initial install uses compensation.
    oldScreenY.removeAll(keepingCapacity: true)
    for cell in cells {
      cell.compensationY = 0
    }
    let changes = {
      for cell in cells {
        cell.contentView.transform = .identity
      }
      for (renderer, plan, generation) in renderers {
        renderer.applyGeometryTransition(to: plan.bubble, generation: generation)
      }
    }
    let finish = {
      for (renderer, _, generation) in renderers {
        renderer.finishGeometryTransition(generation: generation)
      }
    }
    if shouldAnimate {
      let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.88, animations: changes)
      self.animator = animator
      animator.addCompletion { [weak self] _ in
        guard let self, transitionRevision == revision else { return }
        finish()
        self.animator = nil
      }
      animator.startAnimation()
    } else {
      UIView.performWithoutAnimation { changes()
        finish()
      }
    }
    installing = false
    status.text = String(
      format: "Experimental · %d synthetic rows\nPrep %.1f ms (%d changed) · install %.1f ms\n%@ · live chat rendering unchanged",
      update.rows.count,
      update.preparationMS,
      update.measuredCount,
      (CACurrentMediaTime() - start) * 1_000,
      layout.geometry?.isFollowingBottom(at: collection.contentOffset.y) == true ? "Following bottom" : "Reading history"
    )
    drainPending()
  }

  private func compensation(for id: Int64) -> CGFloat {
    guard let oldY = oldScreenY[id], let frame = layout.geometry?.frame(for: id) else { return 0 }
    return oldY - (frame.minY - targetOffset)
  }

  private func descendants(of view: UIView) -> [UIView] {
    guard !view.isHidden else { return [] }
    return [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private func stopAnimation() {
    transitionRevision &+= 1 // Fence the old completion before stopping an interrupted animator.
    animator?.stopAnimation(false)
    animator?.finishAnimation(at: .current)
    animator = nil
    for case let cell as MessageListV2FixtureCell in collection.visibleCells {
      cell.renderer?.cancelPendingGeometryTransitions()
      cell.compensationY = 0
      cell.contentView.transform = .identity
    }
    oldScreenY.removeAll(keepingCapacity: true)
  }

  func scrollViewWillBeginDragging(_: UIScrollView) {
    stopAnimation()
  }

  func scrollViewDidEndDecelerating(_: UIScrollView) {
    drainPending()
  }

  func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { drainPending() }
  }

  private func drainPending() {
    guard !installing, !userIsScrolling, let update = pending else { return }
    pending = nil
    submit(update)
  }

  private func targetIndex() -> Int? {
    let visible = collection.indexPathsForVisibleItems.sorted()
    guard let path = visible.dropFirst(visible.count / 2).first,
          let id = dataSource.itemIdentifier(for: path) else { return nil }
    return messages.firstIndex { $0.id == id }
  }

  @objc private func react() {
    guard let index = targetIndex() else { return }
    toggleReaction(at: index)
    requestPreparation()
  }

  private func toggleReaction(at index: Int) {
    messages[index].reactions = messages[index].reactions.isEmpty
      ? MessageListV2LabFixtures.reactions(messageID: messages[index].message.messageId) : []
  }

  @objc private func grow() {
    guard let index = targetIndex() else { return }
    MessageListV2LabFixtures.grow(&messages[index])
    requestPreparation()
  }

  @objc private func runBurst() {
    burst?.cancel()
    guard let index = targetIndex() else { return }
    let id = messages[index].id
    burst = Task { @MainActor [weak self] in
      for iteration in 0 ..< 12 {
        guard !Task.isCancelled, let self, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        toggleReaction(at: index)
        if iteration.isMultiple(of: 3) { MessageListV2LabFixtures.grow(&messages[index]) }
        requestPreparation()
        do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
      }
    }
  }

  @objc private func appendMessage() {
    messages.append(MessageListV2LabFixtures.message(id: nextID))
    nextID += 1
    requestPreparation()
  }

  @objc private func prependMessages() {
    let older = (0 ..< 10).map { MessageListV2LabFixtures.message(id: nextID + Int64($0)) }
    nextID += 10
    messages.insert(contentsOf: older, at: 0)
    requestPreparation()
  }

  @objc private func deleteMessage() {
    guard let index = targetIndex() else { return }
    messages.remove(at: index)
    requestPreparation()
  }

  @objc private func goToBottom() {
    stopAnimation()
    collection.setContentOffset(CGPoint(x: 0, y: layout.geometry?.maximumOffsetY ?? 0), animated: false)
  }

  @objc private func resizeViewport() {
    resized.toggle()
    bottomConstraint.constant = resized ? -160 : 0
    view.setNeedsLayout()
  }
}

private enum MessageListV2LabFixtures {
  /// Deliberately exclude reply lookup, actions, attachments, images and disclosure state writes.
  private static let catalog = MessageView2PlaygroundFixtures.scenarios.filter {
    [10_001, 10_002, 10_005, 10_006, 10_007].contains($0.id)
  }

  static func messages() -> [FullMessage] {
    (0 ..< 100).map { message(id: 20_000 + Int64($0)) }
  }

  static func message(id: Int64) -> FullMessage {
    var value = catalog[Int(id % Int64(catalog.count))].message
    value.message.messageId = id
    value.message.globalId = id
    if !value.reactions.isEmpty { value.reactions = reactions(messageID: id) }
    return value
  }

  static func reactions(messageID: Int64) -> [FullReaction] {
    catalog[1].message.reactions.map { full in
      var full = full
      full.reaction.messageId = messageID
      return full
    }
  }

  static func grow(_ value: inout FullMessage) {
    let addition = "More fixture text to test wrapping and retained rich-node geometry during an interrupted update."
    let previous = value.message.text ?? ""
    value.message.text = previous + "\n" + addition
    if let payload = value.message.blockContentPayload {
      var content = payload.content
      content.blocks.append(.with {
        $0.paragraph = .with {
          $0.offset = Int64((previous as NSString).length + 1)
          $0.length = Int64((addition as NSString).length)
        }
      })
      value.message.blockContentPayload = BlockContentPayload(content)
    }
  }
}
#endif
