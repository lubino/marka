import CoreGraphics
import Foundation

public struct EditorSettings: Equatable, Sendable {
    public var fontName: String
    public var fontSize: CGFloat
    public var marginMillimetres: CGFloat
    public var showPageNumbers: Bool
    public var autosave: Bool
    public var darkPaper: Bool
    public var showSidebar: Bool
    /// `auto` (fit the page to the window width) or `manual`.
    public var zoomMode: String
    public var zoomFactor: CGFloat
    /// Target word count shown as progress in the document info popover; 0 = off.
    public var wordGoal: Int
    /// Show the page-number control in the toolbar.
    public var showPageControl: Bool

    public static let `default` = EditorSettings(
        fontName: "Times New Roman",
        fontSize: 10,
        marginMillimetres: 20,
        showPageNumbers: true,
        autosave: true,
        darkPaper: false,
        showSidebar: true,
        zoomMode: "auto",
        zoomFactor: 1
    )

    public init(
        fontName: String,
        fontSize: CGFloat,
        marginMillimetres: CGFloat,
        showPageNumbers: Bool,
        autosave: Bool,
        darkPaper: Bool,
        showSidebar: Bool,
        zoomMode: String = "auto",
        zoomFactor: CGFloat = 1,
        wordGoal: Int = 0,
        showPageControl: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.marginMillimetres = marginMillimetres
        self.showPageNumbers = showPageNumbers
        self.autosave = autosave
        self.darkPaper = darkPaper
        self.showSidebar = showSidebar
        self.zoomMode = zoomMode
        self.zoomFactor = zoomFactor
        self.wordGoal = wordGoal
        self.showPageControl = showPageControl
    }

    public var geometry: PageGeometry {
        PageGeometry.a4(marginMillimetres: marginMillimetres, showPageNumbers: showPageNumbers)
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()
    public static let didChange = Notification.Name("sk.lubino.marka.settingsDidChange")
    public static let schemaVersion = 2
    private let defaults: UserDefaults
    private let prefix = "sk.lubino.marka."

    public var current: EditorSettings {
        didSet {
            persist()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var s = EditorSettings.default
        if let name = defaults.string(forKey: prefix + "fontName") { s.fontName = name }
        let size = defaults.double(forKey: prefix + "fontSize")
        if size > 0 { s.fontSize = CGFloat(size) }
        let margin = defaults.double(forKey: prefix + "marginMillimetres")
        if margin > 0 { s.marginMillimetres = CGFloat(margin) }
        if defaults.object(forKey: prefix + "showPageNumbers") != nil {
            s.showPageNumbers = defaults.bool(forKey: prefix + "showPageNumbers")
        }
        if defaults.object(forKey: prefix + "autosave") != nil {
            s.autosave = defaults.bool(forKey: prefix + "autosave")
        }
        s.darkPaper = defaults.bool(forKey: prefix + "darkPaper")
        if defaults.object(forKey: prefix + "showSidebar") != nil {
            s.showSidebar = defaults.bool(forKey: prefix + "showSidebar")
        }
        if let mode = defaults.string(forKey: prefix + "zoomMode") {
            // "wide" was merged into "auto".
            s.zoomMode = mode == "wide" ? "auto" : mode
        }
        let zoom = defaults.double(forKey: prefix + "zoomFactor")
        if zoom > 0 { s.zoomFactor = CGFloat(zoom) }
        s.wordGoal = max(0, defaults.integer(forKey: prefix + "wordGoal"))
        if defaults.object(forKey: prefix + "showPageControl") != nil {
            s.showPageControl = defaults.bool(forKey: prefix + "showPageControl")
        }
        let storedVersion = defaults.integer(forKey: prefix + "settingsVersion")
        if storedVersion < 2 {
            let storedName = defaults.string(forKey: prefix + "fontName")
            let storedSize = defaults.double(forKey: prefix + "fontSize")
            let usedOldDefault = (storedName == nil || storedName == "New York")
                && (storedSize == 0 || abs(storedSize - 11) < 0.01)
            if usedOldDefault {
                s.fontName = EditorSettings.default.fontName
                s.fontSize = EditorSettings.default.fontSize
            }
        }
        self.current = s
        if storedVersion < Self.schemaVersion {
            persist()
        }
    }

    private func persist() {
        defaults.set(Self.schemaVersion, forKey: prefix + "settingsVersion")
        defaults.set(current.fontName, forKey: prefix + "fontName")
        defaults.set(Double(current.fontSize), forKey: prefix + "fontSize")
        defaults.set(Double(current.marginMillimetres), forKey: prefix + "marginMillimetres")
        defaults.set(current.showPageNumbers, forKey: prefix + "showPageNumbers")
        defaults.set(current.autosave, forKey: prefix + "autosave")
        defaults.set(current.darkPaper, forKey: prefix + "darkPaper")
        defaults.set(current.showSidebar, forKey: prefix + "showSidebar")
        defaults.set(current.zoomMode, forKey: prefix + "zoomMode")
        defaults.set(Double(current.zoomFactor), forKey: prefix + "zoomFactor")
        defaults.set(current.wordGoal, forKey: prefix + "wordGoal")
        defaults.set(current.showPageControl, forKey: prefix + "showPageControl")
    }
}
