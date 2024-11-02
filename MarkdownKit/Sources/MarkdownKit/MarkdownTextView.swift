import UIKit

public final class MarkdownTextView: UITextView {
    /// Change notification callback
    public var onMarkdownChange: ((String) -> Void)?

    private let theme: MarkdownTheme
    private let features: Set<MarkdownFeature>

    // Track markdown changes
    private var lastText: String = ""
    private var isUpdatingText = false

    init(theme: MarkdownTheme, features: Set<MarkdownFeature>) {
        self.theme = theme
        self.features = features

        // Create TextKit stack
        let storage = NSTextStorage()
        let container = NSTextContainer(size: .zero)
        let layoutManager = NSLayoutManager()

        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        // Initialize with TextKit stack
        super.init(frame: .zero, textContainer: container)

        setupTextView()
        setupNotifications()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTextView() {
        backgroundColor = theme.backgroundColor
        textColor = theme.textColor
        font = theme.normalFont

        // Disable auto-corrections that might interfere with markdown
        autocorrectionType = .no
        autocapitalizationType = .none
        smartDashesType = .no
        smartQuotesType = .no

        // Enable find interaction for iOS 16+
        if #available(iOS 16.0, *) {
            isFindInteractionEnabled = true
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextChange),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    @objc private func handleTextChange() {
        guard !isUpdatingText else { return }

        // Debounce rapid changes
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(processMarkdownChange),
            object: nil
        )
        perform(#selector(processMarkdownChange), with: nil, afterDelay: 0.1)
    }

    @objc private func processMarkdownChange() {
        let currentText = text ?? ""
        guard currentText != lastText else { return }

        lastText = currentText
        isUpdatingText = true

        // Apply live formatting if enabled
        if features.contains(.autoFormatting) {
            applyAutoFormatting(to: currentText)
        }

        // Notify about markdown changes
        onMarkdownChange?(currentText)

        isUpdatingText = false
    }

    private func applyAutoFormatting(to text: String) {
        guard features.contains(.autoFormatting) else { return }

        var formattedText = text
        let currentSelectedRange = selectedRange

        // Auto-complete markdown pairs
        if text.hasSuffix("**") && !text.hasSuffix("***") {
            formattedText += "**"
        }

        if text.hasSuffix("*") && !text.hasSuffix("**") {
            formattedText += "*"
        }

        if text.hasSuffix("```") {
            formattedText += "\n\n```"
        }

        // Auto-format lists
        if text.hasSuffix("\n- ") {
            // Continue bullet list
            formattedText += "- "
        }

        if let match = text.range(of: "\n\\d+\\. ", options: .regularExpression),
           match.upperBound == text.endIndex
        {
            // Continue numbered list with next number
            let currentNumber = Int(text[match.lowerBound...].prefix(while: { $0.isNumber })) ?? 0
            formattedText += "\(currentNumber + 1). "
        }

        // Only update if changes were made
        if formattedText != text {
            self.text = formattedText
            // Restore cursor position if needed
            selectedRange = currentSelectedRange
        }
    }
}
