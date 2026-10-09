// MARK: – Enumerator.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The display models (DisplayResolution, DisplayMode, DisplayInfo) and the one place
// CoreGraphics is asked about connected displays and their modes.

import AppKit
import CoreGraphics
import IOKit.graphics

// MARK: - Models

/// A resolution as the user thinks of it: the size in points, and whether the mode behind
/// it is HiDPI. The same point size HiDPI and not are distinct choices.
struct DisplayResolution: Hashable, Comparable, Sendable {
    let width: Int
    let height: Int
    let isHiDPI: Bool

    var title: String {
        isHiDPI ? "\(width) × \(height) (HiDPI)" : "\(width) × \(height)"
    }

    /// Largest first, HiDPI ahead of its low-resolution twin.
    static func < (lhs: DisplayResolution, rhs: DisplayResolution) -> Bool {
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        return lhs.isHiDPI && !rhs.isHiDPI
    }
}

/// One CGDisplayMode, reduced to the values the app needs. `ioDisplayModeID` maps it back
/// to the live CGDisplayMode when it is applied.
struct DisplayMode: Hashable, Sendable {
    let ioDisplayModeID: Int32
    /// Size in points — what System Settings calls "looks like".
    let width: Int
    let height: Int
    /// Size in backing pixels; greater than the point size for a HiDPI mode.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Hz. Zero when the display does not report one.
    let refreshRate: Double
    /// The mode macOS picks by default for this display.
    let isDefault: Bool
    /// CoreGraphics' verdict on whether the desktop can run in this mode. Also used to
    /// prefer a usable mode over an unusable twin at the same size and rate.
    let isUsableForDesktopGUI: Bool

    var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }

    var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height, isHiDPI: isHiDPI)
    }

    /// CoreGraphics reports unrounded rates (59.940…); two decimals gives a stable value
    /// to compare and display.
    var roundedRefreshRate: Double { Self.round(refreshRate) }

    private static func round(_ hz: Double) -> Double { (hz * 100).rounded() / 100 }

    /// Always "59.94", independent of the user's locale, matching the old "%.2f".
    private static let twoDecimals = FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
        .precision(.fractionLength(2)).grouping(.never)

    /// "60 Hz", or "59.94 Hz" where the rate is not a whole number.
    static func formatRefreshRate(_ hz: Double) -> String {
        let rounded = round(hz)
        if rounded == rounded.rounded() { return "\(Int(rounded)) Hz" }
        return rounded.formatted(Self.twoDecimals) + " Hz"
    }
}

/// Everything the menu needs to know about one connected display.
struct DisplayInfo: Sendable {
    let id: CGDirectDisplayID
    /// The name System Settings shows, or "Display <id>" when it has none. Two displays
    /// that would share a name get a " (1)", " (2)" suffix; see `Enumerator.disambiguated`.
    let name: String
    let isBuiltin: Bool
    /// The modes that passed the listing filters, in CoreGraphics' order, plus the current
    /// mode, which is always present.
    let modes: [DisplayMode]
    /// The mode currently applied, or nil if CoreGraphics could not say.
    var currentMode: DisplayMode?

    /// The unique resolutions on offer, largest first. With `hiDPIOnly`, the HiDPI ones
    /// plus the current one; a display with no HiDPI modes ignores the filter.
    func resolutions(hiDPIOnly: Bool = false) -> [DisplayResolution] {
        let all = Set(modes.map(\.resolution))
        guard hiDPIOnly else { return all.sorted() }
        var hiDPI = all.filter(\.isHiDPI)
        guard !hiDPI.isEmpty else { return all.sorted() }
        if let current = currentMode?.resolution { hiDPI.insert(current) }
        return hiDPI.sorted()
    }

    /// Whether the display's default mode is among those at `resolution`.
    func isDefault(_ resolution: DisplayResolution) -> Bool {
        modes.contains { $0.resolution == resolution && $0.isDefault }
    }

    /// The reported refresh rates at `resolution`, highest first. Unreported (zero) rates
    /// are omitted.
    func refreshRates(for resolution: DisplayResolution) -> [Double] {
        let rates = modes
            .filter { $0.resolution == resolution && $0.refreshRate > 0 }
            .map(\.roundedRefreshRate)
        return Array(Set(rates)).sorted(by: >)
    }

    /// The mode to apply for `resolution` at `refreshRate`. With no rate named, prefers the
    /// current rate, then the highest available. Usable modes are preferred over the
    /// unusable twins CoreGraphics reports at the same size and rate.
    func mode(for resolution: DisplayResolution, refreshRate: Double? = nil) -> DisplayMode? {
        let candidates = modes
            .filter { $0.resolution == resolution }
            .sorted { $0.isUsableForDesktopGUI && !$1.isUsableForDesktopGUI }
        guard !candidates.isEmpty else { return nil }

        if let refreshRate {
            return candidates.first { $0.roundedRefreshRate == refreshRate }
        }
        // With no rate named, an unusable twin is only a last resort: it must not win just
        // because it matches the current rate when a usable mode exists at another rate.
        let usable = candidates.filter(\.isUsableForDesktopGUI)
        let pool = usable.isEmpty ? candidates : usable
        if let current = currentMode,
           let same = pool.first(where: { $0.roundedRefreshRate == current.roundedRefreshRate }) {
            return same
        }
        return pool.max { $0.refreshRate < $1.refreshRate }
    }
}

// MARK: - Enumerator

/// Stateless: every function is a fresh question to CoreGraphics.
enum Enumerator: Loggable {
    nonisolated static let logTag = "[ENUM]"

    /// The connected displays with their modes and current mode, sorted by id so the menu
    /// order is stable. Main-actor because `NSScreen` is; the CoreGraphics calls take a
    /// few milliseconds, not enough to be worth a hop.
    ///
    /// The current mode is always included, so a display left in a mode the filters hide
    /// still shows a checked row and its refresh rate.
    @MainActor
    static func snapshot(showAllModes: Bool) -> [DisplayInfo] {
        let ids = onlineDisplayIDs()
        let screenNames = Self.screenNamesByID()

        let displays = ids.sorted().map { id in
            var modes = displayModes(for: id, showAllModes: showAllModes)
            let current = currentMode(for: id)
            if let current, !modes.contains(current) {
                modes.append(current)
            }
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            return DisplayInfo(id: id,
                               name: isBuiltin ? "Built-in Display" : screenNames[id] ?? "Display \(id)",
                               isBuiltin: isBuiltin,
                               modes: modes,
                               currentMode: current)
        }
        return disambiguated(displays)
    }

    /// The mode a display is currently in.
    static func currentMode(for id: CGDirectDisplayID) -> DisplayMode? {
        CGDisplayCopyDisplayMode(id).map(DisplayMode.init)
    }

    /// The live CGDisplayMode that `mode` was reduced from. Matched on every reduced value,
    /// not the IOKit mode id alone, since a low-resolution duplicate can share an id with
    /// the mode it duplicates; reducing the candidate the same way keeps the comparison
    /// consistent with how `mode` was built. Searches the unfiltered list: `mode` was
    /// already vetted when it was listed.
    static func cgDisplayMode(matching mode: DisplayMode, on id: CGDirectDisplayID) -> CGDisplayMode? {
        allCGDisplayModes(for: id, showAllModes: true).first { DisplayMode($0) == mode }
    }

    // MARK: Private

    /// Numbers the displays in each group sharing a name, e.g. two U2790Bs become
    /// "U2790B (1)" and "U2790B (2)", so the user can tell which one a row changes. The
    /// numbering follows the EDID serial number, so each physical monitor keeps its number
    /// across reconnects, sleep and port changes. Monitors reporting no serial (zero) come
    /// after those that do, numbered left to right, then top to bottom, by arrangement; the
    /// display ID breaks any remaining tie, as when two displays mirror one another.
    private static func disambiguated(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        var suffixes: [CGDirectDisplayID: Int] = [:]
        for group in Dictionary(grouping: displays, by: \.name).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                let (l, r) = (CGDisplaySerialNumber(lhs.id), CGDisplaySerialNumber(rhs.id))
                if (l == 0) != (r == 0) { return l != 0 }
                if l != r { return l < r }
                let (lb, rb) = (CGDisplayBounds(lhs.id), CGDisplayBounds(rhs.id))
                if lb.minX != rb.minX { return lb.minX < rb.minX }
                if lb.minY != rb.minY { return lb.minY < rb.minY }
                return lhs.id < rhs.id
            }
            for (index, display) in ordered.enumerated() {
                suffixes[display.id] = index + 1
            }
        }
        guard !suffixes.isEmpty else { return displays }
        return displays.map { display in
            guard let suffix = suffixes[display.id] else { return display }
            return DisplayInfo(id: display.id,
                               name: "\(display.name) (\(suffix))",
                               isBuiltin: display.isBuiltin,
                               modes: display.modes,
                               currentMode: display.currentMode)
        }
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard unsafe CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard unsafe CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func displayModes(for id: CGDirectDisplayID, showAllModes: Bool) -> [DisplayMode] {
        allCGDisplayModes(for: id, showAllModes: showAllModes).map(DisplayMode.init)
    }

    /// Always asks with `kCGDisplayShowDuplicateLowResolutionModes`: without it CoreGraphics
    /// hides one of each HiDPI/low-resolution pair, and on a 4K panel the hidden one was the
    /// mode the display was actually in.
    private static func allCGDisplayModes(for id: CGDirectDisplayID, showAllModes: Bool) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let array = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            log("No display modes reported for display \(id).", level: .warning)
            return []
        }
        return showAllModes ? array : array.filter { isListedByDefault($0) }
    }

    /// Usable for the desktop, and not below the floor in both dimensions (in points, so
    /// a HiDPI 960 × 540 counts as 960 × 540).
    private static func isListedByDefault(_ mode: CGDisplayMode) -> Bool {
        mode.isUsableForDesktopGUI()
            && (mode.width >= Preferences.minimumListedWidth
                || mode.height >= Preferences.minimumListedHeight)
    }

    /// `NSScreen.localizedName` keyed by CGDirectDisplayID. Only active (drawing) displays
    /// have an NSScreen; a mirrored secondary gets the "Display <id>" fallback.
    @MainActor
    private static func screenNamesByID() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }
}

private extension DisplayMode {
    init(_ mode: CGDisplayMode) {
        self.init(ioDisplayModeID: mode.ioDisplayModeID,
                  width: Int(mode.width),
                  height: Int(mode.height),
                  pixelWidth: Int(mode.pixelWidth),
                  pixelHeight: Int(mode.pixelHeight),
                  refreshRate: max(0, mode.refreshRate),
                  isDefault: mode.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0,
                  isUsableForDesktopGUI: mode.isUsableForDesktopGUI())
    }
}
