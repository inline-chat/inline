import Cocoa
import SwiftUI

class MainViewController: NSViewController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
//        view.layer?.backgroundColor = NSColor.windowBackgroundColor.
        // Translucent
        let effect = NSVisualEffectView()
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.material = .sidebar
        view.addSubview(effect)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let mainSplitViewController = MainSplitViewController()
        addChild(mainSplitViewController)
        view.addSubview(mainSplitViewController.view)
        
        mainSplitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainSplitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            mainSplitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSplitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSplitViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

class MainSplitViewController: NSSplitViewController {
    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure the split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.delegate = self
        
        // Create and configure the sidebar view controller
        let sidebarViewController = SidebarViewController()
        sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarViewController)
        //        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(251)

        sidebarItem.canCollapse = true
//        sidebarItem.preferredThicknessFraction = 0.2 // 20% of the window width
        sidebarItem.minimumThickness = 150
        sidebarItem.isSpringLoaded = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.maximumThickness = 300

        // Create and configure the content view controller
        let contentViewController = MainContentViewController()
        contentItem = NSSplitViewItem(viewController: contentViewController)

        // Add the split view items
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        
        // Set up notification for sidebar collapse/expand
        NotificationCenter.default.addObserver(self, selector: #selector(splitViewDidResizeSubviews2), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        updateToolbarPadding()
    }
  
    @objc func splitViewDidResizeSubviews2(_ notification: Notification) {
        updateToolbarPadding()
    }
  
    private func updateToolbarPadding() {
        guard let contentViewController = contentItem.viewController as? MainContentViewController else { return }
        print("collapse changed")
        if sidebarItem.isCollapsed {
            contentViewController.updateToolbarLeftPadding(80) // Adjust this value as needed
        } else {
            contentViewController.updateToolbarLeftPadding(16) // Default padding
        }
    }
}

class SidebarViewController: NSViewController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
//        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

class CustomToolbar: NSVisualEffectView {
    let titleLabel: NSTextField
    let actionButton: NSButton
    let segmentedControl: NSSegmentedControl
    
    private var leadingConstraint: NSLayoutConstraint?

    init(frame: NSRect, leftPadding: CGFloat = 0) {
        titleLabel = NSTextField(labelWithString: "Custom Toolbar")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        
        actionButton = NSButton(title: "Action", target: nil, action: #selector(actionButtonClicked))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        
        segmentedControl = NSSegmentedControl(labels: ["One", "Two", "Three"], trackingMode: .selectOne, target: nil, action: #selector(segmentChanged))
        segmentedControl.controlSize = .small
        
        super.init(frame: frame)
        
        material = .headerView
        state = .active
        
        let leftStackView = NSStackView(views: [titleLabel])
        let rightStackView = NSStackView(views: [actionButton, segmentedControl])
        let mainStackView = NSStackView(views: [leftStackView, rightStackView])
        
        leftStackView.orientation = .horizontal
        leftStackView.alignment = .centerY
        leftStackView.spacing = 8
        
        rightStackView.orientation = .horizontal
        rightStackView.alignment = .centerY
        rightStackView.spacing = 8
        
        mainStackView.orientation = .horizontal
        mainStackView.alignment = .centerY
        mainStackView.distribution = .equalSpacing
        mainStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 16)
        
        addSubview(mainStackView)
        
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainStackView.topAnchor.constraint(equalTo: topAnchor),
            mainStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mainStackView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
           
        leadingConstraint = mainStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        leadingConstraint?.isActive = true
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func actionButtonClicked() {
        print("Action button clicked")
    }
    
    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        print("Selected segment: \(sender.selectedSegment)")
    }
    
    func updateLeftPadding(_ padding: CGFloat) {
        leadingConstraint?.constant = padding
        layoutSubtreeIfNeeded()
    }
}

class MainContentViewController: NSViewController {
    private var customToolbar: CustomToolbar!

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        
        customToolbar = CustomToolbar(frame: .zero)
        let contentView = NSView()
        
        view.addSubview(customToolbar)
        view.addSubview(contentView)
        
        customToolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            customToolbar.topAnchor.constraint(equalTo: view.topAnchor),
            customToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            customToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            customToolbar.heightAnchor.constraint(equalToConstant: 38),
            
            contentView.topAnchor.constraint(equalTo: customToolbar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        let label = NSTextField(labelWithString: "Main Content")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        
        contentView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    
    func updateToolbarLeftPadding(_ padding: CGFloat) {
        customToolbar.updateLeftPadding(padding)
    }
}
