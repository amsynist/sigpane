import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Sigpane -> DockTilePlugin
    static let ghosttyIconDidChange = Notification.Name("com.amsynist.ghosttyx.iconDidChange")
}
