import Foundation

/// Global, persisted flags (SPEC §5.1, §6.1). `isLocked` is the only one so
/// far: Lock mode is a global setting that outlives any single document and
/// survives relaunch (FR-25).
enum AppSettings {

    private static let isLockedKey = "PenPDF.isLocked"

    static var isLocked: Bool {
        get { UserDefaults.standard.bool(forKey: isLockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isLockedKey) }
    }
}
