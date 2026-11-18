import AppKit
import MarkaCore

final class SettingsWindowController: NSWindowController {
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let marginField = NSTextField()
    private let pageNumbers = NSButton(checkboxWithTitle: "Show page numbers", target: nil, action: nil)
    private let autosave = NSButton(checkboxWithTitle: "Autosave", target: nil, action: nil)
    private let darkPaper = NSButton(checkboxWithTitle: "Dark paper", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Marka Settings"
        self.init(window: window)
        window.contentView = build()
        window.center()
        load()
    }

    private func build() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        fontPopup.addItems(withTitles: ["New York", "SF Pro", "Times New Roman", "Georgia", "Helvetica Neue"])
        sizeField.placeholderString = "11"
        marginField.placeholderString = "20"
        [fontPopup, sizeField, marginField, pageNumbers, autosave, darkPaper].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let fontLabel = label("Font")
        let sizeLabel = label("Size (pt)")
        let marginLabel = label("Margins (mm)")
        [fontLabel, sizeLabel, marginLabel].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            fontLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            fontLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            fontPopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontPopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 140),
            fontPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            sizeLabel.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 16),
            sizeLabel.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            sizeField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizeField.leadingAnchor.constraint(equalTo: fontPopup.leadingAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 80),

            marginLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 16),
            marginLabel.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            marginField.centerYAnchor.constraint(equalTo: marginLabel.centerYAnchor),
            marginField.leadingAnchor.constraint(equalTo: fontPopup.leadingAnchor),
            marginField.widthAnchor.constraint(equalToConstant: 80),

            pageNumbers.topAnchor.constraint(equalTo: marginLabel.bottomAnchor, constant: 20),
            pageNumbers.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            autosave.topAnchor.constraint(equalTo: pageNumbers.bottomAnchor, constant: 8),
            autosave.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor),
            darkPaper.topAnchor.constraint(equalTo: autosave.bottomAnchor, constant: 8),
            darkPaper.leadingAnchor.constraint(equalTo: fontLabel.leadingAnchor)
        ])

        fontPopup.target = self
        fontPopup.action = #selector(commit)
        sizeField.target = self
        sizeField.action = #selector(commit)
        marginField.target = self
        marginField.action = #selector(commit)
        pageNumbers.target = self
        pageNumbers.action = #selector(commit)
        autosave.target = self
        autosave.action = #selector(commit)
        darkPaper.target = self
        darkPaper.action = #selector(commit)
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
        sizeField.stringValue = String(Int(s.fontSize))
        marginField.stringValue = String(Int(s.marginMillimetres))
        pageNumbers.state = s.showPageNumbers ? .on : .off
        autosave.state = s.autosave ? .on : .off
        darkPaper.state = s.darkPaper ? .on : .off
    }

    @objc private func commit() {
        var s = SettingsStore.shared.current
        s.fontName = fontPopup.titleOfSelectedItem ?? s.fontName
        if let size = Double(sizeField.stringValue), size >= 8, size <= 36 { s.fontSize = CGFloat(size) }
        if let margin = Double(marginField.stringValue), margin >= 8, margin <= 40 { s.marginMillimetres = CGFloat(margin) }
        s.showPageNumbers = pageNumbers.state == .on
        s.autosave = autosave.state == .on
        s.darkPaper = darkPaper.state == .on
        SettingsStore.shared.current = s
    }
}
