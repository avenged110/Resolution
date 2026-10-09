// MARK: – Preferences.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized UserDefaults-backed preferences: key names, registered defaults and typed
// accessors, so no other file touches UserDefaults directly.

import Foundation

struct Preferences: Loggable {
    nonisolated static let logTag = "[Preferences]"

    // Read from the main actor and from LoggerCore's executor (the logger's enabled
    // predicate). UserDefaults.standard is thread-safe for these calls. It isn't Sendable,
    // so it is fetched on each access rather than stored in a static.
    //
    // Registration is a lazy, thread-safe static every access goes through, so no accessor
    // can reach the suite before the defaults are in place.
    private static let registration: Void = {
        UserDefaults.standard.register(defaults: registeredDefaults())
    }()

    private static var defaults: UserDefaults {
        _ = registration
        return UserDefaults.standard
    }

    // MARK: - Centralized Internal Constants

    /// Floor for the default mode listing, in points. A mode smaller than this in BOTH
    /// dimensions is hidden unless `showAllModes` is on.
    static let minimumListedWidth  = 1024
    static let minimumListedHeight = 768

    // MARK: - Keys
    private enum Keys {
        static let loggingEnabled =
            "preferences.loggingEnabled"
        static let showAllModes =
            "preferences.showAllModes"
        static let onlyShowHiDPI =
            "preferences.onlyShowHiDPI" }

    // Re-exposed for @AppStorage bindings, so the key strings have one definition.
    static let loggingEnabledKey = Keys.loggingEnabled
    static let showAllModesKey   = Keys.showAllModes
    static let onlyShowHiDPIKey  = Keys.onlyShowHiDPI

    // A function rather than a stored dictionary, which strict concurrency rejects as
    // shared mutable state.
    private static func registeredDefaults() -> [String: Any] {
        return [
            Keys.loggingEnabled: false,
            Keys.showAllModes:   false,
            Keys.onlyShowHiDPI:  false ] }

    /// Forces `defaults` to initialize. Registration happens regardless; AppDelegate calls
    /// this so the suite is resolved before the logger's enabled predicate first runs.
    static func ensureDefaultsRegistered() { _ = defaults }

    // MARK: - Toggles

    // The Settings toggles write through @AppStorage, which commits before their onChange
    // handlers run, so these setters are deduplicated no-ops on that path.
    static var loggingEnabled: Bool {
        get { return defaults.bool(forKey: Keys.loggingEnabled) }
        set {
            setIfChanged(newValue, forKey: Keys.loggingEnabled,
                logMessage: "loggingEnabled set to \(newValue)") } }

    /// Lists every mode CoreGraphics reports, including those it flags as unusable for the
    /// desktop and those below the floor above. DisplayStore re-enumerates when it changes.
    static var showAllModes: Bool {
        get { return defaults.bool(forKey: Keys.showAllModes) }
        set {
            setIfChanged(newValue, forKey: Keys.showAllModes,
                logMessage: "showAllModes set to \(newValue)") } }

    /// Restricts the Resolution submenu to HiDPI resolutions. Presentation only: the
    /// snapshot, the Refresh Rate submenu and mode application are unaffected.
    static var onlyShowHiDPI: Bool {
        get { return defaults.bool(forKey: Keys.onlyShowHiDPI) }
        set {
            setIfChanged(newValue, forKey: Keys.onlyShowHiDPI,
                logMessage: "onlyShowHiDPI set to \(newValue)") } }

    // MARK: - Change Guard
    // Writes only if the value differs from the current (or registered default) one.
    private static func setIfChanged(_ value: Bool, forKey key: String,
        logMessage: String? = nil) {
        guard defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        if let message = logMessage { log(message) } }
}
