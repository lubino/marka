import AppKit

/// Liquid Glass (`NSGlassEffectView`) on macOS 26+, with `NSVisualEffectView` as the fallback.
/// Uses runtime class lookup so the project still compiles against the macOS 14/15 SDK.
@MainActor
enum GlassChrome {
    enum Style {
        case regular
        case clear
    }

    static var usesLiquidGlass: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    static func wrap(
        _ content: NSView,
        style: Style = .regular,
        cornerRadius: CGFloat = 0,
        interactive: Bool = false,
        tint: NSColor? = nil
    ) -> NSView {
        if let glass = makeLiquidGlass(
            content: content,
            style: style,
            cornerRadius: cornerRadius,
            interactive: interactive,
            tint: tint
        ) {
            return glass
        }
        return makeVibrant(content: content)
    }

    static func setTint(_ view: NSView, _ color: NSColor?) {
        guard isLiquidGlass(view), view.responds(to: NSSelectorFromString("setTintColor:")) else { return }
        view.setValue(color, forKey: "tintColor")
    }

    static func isLiquidGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("GlassEffect")
    }

    private static func makeLiquidGlass(
        content: NSView,
        style: Style,
        cornerRadius: CGFloat,
        interactive: Bool,
        tint: NSColor?
    ) -> NSView? {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return nil
        }
        let glass = glassClass.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        if glass.responds(to: NSSelectorFromString("setContentView:")) {
            glass.setValue(content, forKey: "contentView")
        } else {
            glass.addSubview(content)
            content.frame = glass.bounds
        }
        glass.setValue(NSNumber(value: Double(cornerRadius)), forKey: "cornerRadius")
        glass.setValue(NSNumber(value: style == .clear ? 1 : 0), forKey: "style")
        if let tint {
            glass.setValue(tint, forKey: "tintColor")
        }
        // `effectIsInteractive` only exists on macOS 27+; KVC on 26 would throw NSUnknownKeyException.
        if interactive, glass.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
            glass.setValue(true, forKey: "effectIsInteractive")
        }
        return glass
    }

    private static func makeVibrant(content: NSView) -> NSView {
        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        content.frame = effect.bounds
        return effect
    }
}
