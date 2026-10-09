// MARK: – DisplayStore.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Single source of truth for the connected displays and their modes: refreshed by the
// Watcher on every reconfiguration and read by ResolutionMenu when it builds.

import CoreGraphics
import Foundation

@MainActor @Observable
final class DisplayStore: Loggable {
    nonisolated static let logTag = "[DisplayStore]"

    /// The current snapshot, sorted by display id.
    private(set) var displays: [DisplayInfo] = []

    /// The `showAllModes` value the snapshot was taken under, so a change in Settings is
    /// noticed on the next `reconcile()`.
    private var snapshotShowsAllModes = false

    func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// Re-enumerates everything. Called at launch and from the Watcher.
    func refresh() {
        let showAll = Preferences.showAllModes
        displays = Enumerator.snapshot(showAllModes: showAll)
        snapshotShowsAllModes = showAll

        let summary = displays.map { display in
            let current = display.currentMode.map {
                "\($0.resolution.title) @ \(DisplayMode.formatRefreshRate($0.refreshRate))"
            } ?? "unknown mode"
            return "\(display.name) [\(display.id)]: \(display.modes.count) modes, current \(current)"
        }
        log("Enumerated \(displays.count) display(s): \(summary.joined(separator: "; "))")
    }

    /// The cheap pre-open pass: re-reads each display's current mode so the checkmarks
    /// reflect a change made in System Settings between reconfiguration events. Falls
    /// back to a full `refresh()` if the listing preference changed or a display is now
    /// in a mode the snapshot does not list.
    func reconcile() {
        guard snapshotShowsAllModes == Preferences.showAllModes else {
            refresh()
            return
        }
        for index in displays.indices {
            let current = Enumerator.currentMode(for: displays[index].id)
            if let current, !displays[index].modes.contains(current) {
                refresh()
                return
            }
            displays[index].currentMode = current
        }
    }
}
