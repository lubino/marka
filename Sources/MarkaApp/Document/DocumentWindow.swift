import AppKit

/// Document window whose native tab bar is shown only while its tab group holds two or more tabs.
///
/// AppKit remembers an explicit "Show Tab Bar" per tabbing identifier and would then keep the bar for a
/// single window, so visibility is synced explicitly after every change to a tab group. The bar itself
/// is always the system one (rounded Liquid Glass on macOS 26+).
final class DocumentWindow: NSWindow {
    /// Show the bar for multi-tab groups, hide it for lone windows — for every document window.
    static func syncAllTabBars() {
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows.compactMap({ $0 as? DocumentWindow }) where window.isVisible || window.tabGroup != nil {
            guard let group = window.tabGroup, seen.insert(ObjectIdentifier(group)).inserted else { continue }
            window.syncTabBarVisibility()
        }
    }

    /// Defer until AppKit has finished moving windows between groups.
    static func scheduleSync() {
        DispatchQueue.main.async { syncAllTabBars() }
    }

    func syncTabBarVisibility() {
        guard let group = tabGroup else { return }
        let shouldShow = group.windows.count > 1
        if group.isTabBarVisible != shouldShow {
            super.toggleTabBar(nil)
        }
    }

    /// The bar follows the tab count; the menu toggle would only fight that.
    override func toggleTabBar(_ sender: Any?) {}

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) { return false }
        return super.validateMenuItem(menuItem)
    }

    override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
        super.addTabbedWindow(window, ordered: ordered)
        syncTabBarVisibility()
        Self.scheduleSync()
    }

    override func moveTabToNewWindow(_ sender: Any?) {
        super.moveTabToNewWindow(sender)
        Self.scheduleSync()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)
        Self.scheduleSync()
    }

    override func close() {
        super.close()
        Self.scheduleSync()
    }
}
