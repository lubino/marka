import AppKit
import MarkaCore

/// Image options (the image card's gear): what GitHub's `<img>` understands — alt text, title,
/// width, height and alignment. Applied when the popover closes (or with Done).
final class ImageOptionsViewController: NSViewController, NSPopoverDelegate {
    var onApply: ((ImageOptions) -> Void)?
    weak var popover: NSPopover?
    private var options: ImageOptions
    private let naturalSize: CGSize?
    private let altField = NSTextField()
    private let titleField = NSTextField()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let alignControl = NSSegmentedControl(labels: ["Default", "Left", "Center", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    private var applied = false
    private static let aligns = ["", "left", "center", "right"]

    init(options: ImageOptions, naturalSize: CGSize?) {
        self.options = options
        self.naturalSize = naturalSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Image Options")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        altField.stringValue = options.alt
        altField.placeholderString = "Describes the image (accessibility)"
        titleField.stringValue = options.title
        titleField.placeholderString = "Shown when hovering"
        widthField.stringValue = options.width
        heightField.stringValue = options.height
        let natural = naturalSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—"
        widthField.placeholderString = naturalSize.map { "\(Int($0.width))" } ?? "auto"
        heightField.placeholderString = "auto"
        for field in [widthField, heightField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let size = NSStackView(views: [widthField, NSTextField(labelWithString: "×"), heightField, Self.hint("px or %")])
        size.spacing = 6
        alignControl.selectedSegment = Self.aligns.firstIndex(of: options.align) ?? 0
        alignControl.segmentDistribution = .fillEqually
        let grid = NSGridView(views: [
            [Self.label("Alt text"), altField],
            [Self.label("Title"), titleField],
            [Self.label("Size"), size],
            [NSGridCell.emptyContentView, Self.hint("Original size: \(natural). Leave empty for the natural size; one value keeps the proportions.")],
            [Self.label("Alignment"), alignControl]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        altField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        titleField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        alignControl.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let reset = NSButton(title: "Original Size", target: self, action: #selector(resetSize))
        let done = NSButton(title: "Done", target: self, action: #selector(apply))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), done])
        let note = Self.hint("Saved as GitHub-compatible <img> when size or alignment is set.")
        let stack = NSStackView(views: [title, grid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])
        view = container
        preferredContentSize = container.fittingSize
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 250
        return label
    }

    @objc private func resetSize() {
        widthField.stringValue = ""
        heightField.stringValue = ""
    }

    var currentOptions: ImageOptions {
        func clean(_ value: String) -> String {
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            if v.hasSuffix("%"), Double(v.dropLast()) != nil { return v }
            let digits = v.hasSuffix("px") ? String(v.dropLast(2)) : v
            return Double(digits).map { String(Int($0.rounded())) } ?? ""
        }
        return ImageOptions(
            alt: altField.stringValue,
            title: titleField.stringValue.trimmingCharacters(in: .whitespaces),
            width: clean(widthField.stringValue),
            height: clean(heightField.stringValue),
            align: Self.aligns[max(0, alignControl.selectedSegment)]
        )
    }

    @objc func apply() {
        guard !applied else { return }
        applied = true
        onApply?(currentOptions)
        popover?.performClose(nil)
    }

    /// Clicking away applies too (like the equation editor).
    func popoverWillClose(_ notification: Notification) { apply() }

    // Testing
    func testSet(width: String, height: String, align: Int, alt: String) {
        _ = view
        widthField.stringValue = width
        heightField.stringValue = height
        alignControl.selectedSegment = align
        altField.stringValue = alt
    }
}
