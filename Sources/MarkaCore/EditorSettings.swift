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

    public static let `default` = EditorSettings(
        fontName: "New York",
        fontSize: 11,
        marginMillimetres: 20,
        showPageNumbers: true,
        autosave: true,
        darkPaper: false,
        showSidebar: true
    )

    public init(
        fontName: String,
        fontSize: CGFloat,
        marginMillimetres: CGFloat,
        showPageNumbers: Bool,
        autosave: Bool,
        darkPaper: Bool,
        showSidebar: Bool
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.marginMillimetres = marginMillimetres
        self.showPageNumbers = showPageNumbers
        self.autosave = autosave
        self.darkPaper = darkPaper
        self.showSidebar = showSidebar
    }

    public var geometry: PageGeometry {
        PageGeometry.a4(marginMillimetres: marginMillimetres, showPageNumbers: showPageNumbers)
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()
    public static let didChange = Notification.Name("sk.lubino.marka.settingsDidChange")
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
        self.current = s
    }

    private func persist() {
        defaults.set(current.fontName, forKey: prefix + "fontName")
        defaults.set(Double(current.fontSize), forKey: prefix + "fontSize")
        defaults.set(Double(current.marginMillimetres), forKey: prefix + "marginMillimetres")
        defaults.set(current.showPageNumbers, forKey: prefix + "showPageNumbers")
        defaults.set(current.autosave, forKey: prefix + "autosave")
        defaults.set(current.darkPaper, forKey: prefix + "darkPaper")
        defaults.set(current.showSidebar, forKey: prefix + "showSidebar")
    }
}
