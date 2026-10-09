// MARK: – Setter.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Applies a display mode via CGDisplaySetDisplayMode.

import CoreGraphics
import Foundation

enum SetterError: Error, LocalizedError {
    case noMatchingMode
    case failedToSetMode(CGError)

    var errorDescription: String? {
        switch self {
        case .noMatchingMode:
            "The requested display mode is no longer available"
        case .failedToSetMode(let error):
            "CoreGraphics failed to set the display mode (CGError \(error.rawValue))"
        }
    }
}

@MainActor
enum Setter: Loggable {
    nonisolated static let logTag = "[Setter]"

    /// Applies `mode` to `displayID`. The live CGDisplayMode is looked up again, so a
    /// display that has since been unplugged or re-enumerated fails with `.noMatchingMode`.
    ///
    /// `CGDisplaySetDisplayMode` is synchronous and configures permanently, so the change
    /// persists across logins as it would from System Settings; the reconfiguration
    /// callback then drives DisplayStore's refresh.
    static func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID) throws {
        guard let cgMode = Enumerator.cgDisplayMode(matching: mode, on: displayID)
        else { throw SetterError.noMatchingMode }

        let error = CGDisplaySetDisplayMode(displayID, cgMode, nil)
        guard error == .success else { throw SetterError.failedToSetMode(error) }

        log("Display \(displayID) set to \(mode.resolution.title) @ \(DisplayMode.formatRefreshRate(mode.refreshRate)).")
    }
}
