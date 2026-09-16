import UIKit

/// Builds the `UIBarButtonItem`s for the Reader's nav bar (§7). Pure factory —
/// no state, no logic. `ReaderViewController` owns wiring and enable/disable.
enum ReaderToolbar {

    static func filesItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Files"
        return item
    }

    static func lockItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "lock.open"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Lock"
        return item
    }

    static func previousPageItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "chevron.up"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Previous Page"
        return item
    }

    static func nextPageItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Next Page"
        return item
    }

    static func undoItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Undo"
        return item
    }

    static func redoItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.forward"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Redo"
        return item
    }

    static func paletteItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "pencil.tip.crop.circle"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Tool Palette"
        return item
    }

    #if DEBUG
    /// Debug builds only (FR-18a): ink on/off so the simulator's mouse can
    /// scroll without drawing. Never present in Release.
    static func debugInkToggleItem(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "pencil.slash"),
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = "Debug: Ink On/Off"
        return item
    }
    #endif
}
