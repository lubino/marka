import AppKit
import MarkaCore

final class SettingsWindowController: NSWindowController {
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let marginField = NSTextField()
    private let pageNumbers = NSButton(checkboxWithTitle: "Show page numbers", target: nil, action: nil)
    private let autosave = NSButton(checkboxWithTitle: "Autosave", target: nil, action: nil)
    private let darkPaper = NSButton(checkboxWithTitle: "Dark paper", target: nil, action: nil)
    private let pageControl = NSButton(checkboxWithTitle: "Show page number in toolbar", target: nil, action: nil)
    private let goalField = NSTextField()
    private static let fontChoices = [
        "Times New Roman", "Times", "New York", "Georgia", "Palatino", "Helvetica Neue", "SF Pro"
    ]
    private static let sizeChoices: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24]

    var hasFontControls: Bool {
        fontPopup.superview != nil && sizePopup.superview != nil && !fontPopup.itemTitles.isEmpty
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Marka Settings"
        self.init(window: window)
        window.contentView = GlassChrome.wrap(build(), style: .regular, cornerRadius: 0)
        window.center()
        load()
    }

    private func build() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 360))
        fontPopup.addItems(withTitles: Self.fontChoices)
        for size in Self.sizeChoices {
            sizePopup.addItem(withTitle: "\(Int(size)) pt")
            sizePopup.lastItem?.representedObject = NSNumber(value: Double(size))
        }
        marginField.placeholderString = "20"
        goalField.placeholderString = "Off"
        let goalFormatter = NumberFormatter()
        goalFormatter.allowsFloats = false
        goalFormatter.minimum = 0
        goalFormatter.maximum = 1_000_000
        goalField.formatter = goalFormatter
        [fontPopup, sizePopup, marginField, goalField, pageNumbers, autosave, darkPaper, pageControl].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let fontLabel = label("Font")
        let sizeLabel = label("Size")
        let marginLabel = label("Margins (mm)")
        let goalLabel = label("Word goal")
        let goalHint = label("words (empty = off)")
        goalHint.textColor = .secondaryLabelColor
        [fontLabel, sizeLabel, marginLabel, goalLabel, goalHint].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            fontLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            fontLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            fontPopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontPopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 140),
            fontPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            sizeLabel.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 16),
            sizeLabel.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            sizePopup.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizePopup.leadingAnchor.constraint(equalTo: fontPopup.leadingAnchor),
            sizePopup.widthAnchor.constraint(equalToConstant: 100),

            marginLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 16),
            marginLabel.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            marginField.centerYAnchor.constraint(equalTo: marginLabel.centerYAnchor),
            marginField.leadingAnchor.constraint(equalTo: fontPopup.leadingAnchor),
            marginField.widthAnchor.constraint(equalToConstant: 80),

            goalLabel.topAnchor.constraint(equalTo: marginLabel.bottomAnchor, constant: 16),
            goalLabel.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            goalField.centerYAnchor.constraint(equalTo: goalLabel.centerYAnchor),
            goalField.leadingAnchor.constraint(equalTo: fontPopup.leadingAnchor),
            goalField.widthAnchor.constraint(equalToConstant: 80),
            goalHint.centerYAnchor.constraint(equalTo: goalLabel.centerYAnchor),
            goalHint.leadingAnchor.constraint(equalTo: goalField.trailingAnchor, constant: 8),

            pageNumbers.topAnchor.constraint(equalTo: goalLabel.bottomAnchor, constant: 20),
            pageNumbers.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            autosave.topAnchor.constraint(equalTo: pageNumbers.bottomAnchor, constant: 8),
            autosave.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            darkPaper.topAnchor.constraint(equalTo: autosave.bottomAnchor, constant: 8),
            darkPaper.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            pageControl.topAnchor.constraint(equalTo: darkPaper.bottomAnchor, constant: 8),
            pageControl.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor)
        ])

        fontPopup.target = self
        fontPopup.action = #selector(commit)
        sizePopup.target = self
        sizePopup.action = #selector(commit)
        marginField.target = self
        marginField.action = #selector(commit)
        pageNumbers.target = self
        pageNumbers.action = #selector(commit)
        autosave.target = self
        autosave.action = #selector(commit)
        darkPaper.target = self
        darkPaper.action = #selector(commit)
        goalField.target = self
        goalField.action = #selector(commit)
        pageControl.target = self
        pageControl.action = #selector(commit)
        return view
    }

    private func label(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func load() {
        let s = SettingsStore.shared.current
        if fontPopup.itemTitles.contains(s.fontName) {
            fontPopup.selectItem(withTitle: s.fontName)
        }
        if let index = Self.sizeChoices.firstIndex(of: s.fontSize) {
            sizePopup.selectItem(at: index)
        } else if let nearest = Self.sizeChoices.enumerated().min(by: { abs($0.element - s.fontSize) < abs($1.element - s.fontSize) }) {
            sizePopup.selectItem(at: nearest.offset)
        }
        marginField.stringValue = String(Int(s.marginMillimetres))
        pageNumbers.state = s.showPageNumbers ? .on : .off
        autosave.state = s.autosave ? .on : .off
        darkPaper.state = s.darkPaper ? .on : .off
        goalField.stringValue = s.wordGoal > 0 ? String(s.wordGoal) : ""
        pageControl.state = s.showPageControl ? .on : .off
    }

    @objc private func commit() {
        var s = SettingsStore.shared.current
        s.fontName = fontPopup.titleOfSelectedItem ?? s.fontName
        if let number = sizePopup.selectedItem?.representedObject as? NSNumber {
            s.fontSize = CGFloat(number.doubleValue)
        }
        if let margin = Double(marginField.stringValue), margin >= 8, margin <= 40 { s.marginMillimetres = CGFloat(margin) }
        s.showPageNumbers = pageNumbers.state == .on
        s.autosave = autosave.state == .on
        s.darkPaper = darkPaper.state == .on
        s.wordGoal = max(0, Int(goalField.stringValue.filter(\.isNumber)) ?? 0)
        s.showPageControl = pageControl.state == .on
        SettingsStore.shared.current = s
    }
}
