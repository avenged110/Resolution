// MARK: – ResolutionMenu.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The status menu — one section per display with Resolution and Refresh Rate submenus,
// plus the Settings/About/Quit tail — and the Settings window, over the shared kits.

import Cocoa
import IOKit.ps
import SwiftUI

@MainActor
final class ResolutionMenu: Loggable {
    nonisolated static let logTag = "[MenuController]"

    // MARK: - Dependencies
    private let store: DisplayStore

    private static let displaySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!

    // MARK: - Initialization

    init(store: DisplayStore) {
        self.store = store
    }

    // MARK: – Settings window
    //
    // Built lazily and held for the app's lifetime (the controller builds its NSWindow on
    // open and discards it on close). `_settings` staying nil lets the termination path
    // check for an open window without building the controller.
    private var _settings: SettingsWindowController?
    private var settings: SettingsWindowController {
        if let existing = _settings { return existing }
        let created = Self.makeSettingsController()
        _settings = created
        return created
    }

    private static func makeSettingsController() -> SettingsWindowController {
        SettingsWindowController(.init(
            title: "Resolution Settings",
            sizing: .fitToContent(width: 500),
            tabs: [
                .swiftUI(id: "general", title: "General") { GeneralTabView() },
            ],
            // One tab, so no tab bar.
            tabBar: .hidden,
            styleMask: [.titled, .closable, .miniaturizable],
            // Without a temporary main menu an LSUIElement app's window has no
            // Cut/Copy/Paste and no ⌘W.
            installsTemporaryMainMenu: true,
            // The kit's nil branch shows the About panel but without ⌘?.
            aboutMenuAction: #selector(AppDelegate.showAboutPanel(_:))))
    }

    // MARK: – Status menu
    //
    // Rebuilt from the store on every open; the submenus are built on expansion.
    private lazy var menu = MenuController(.init(
        appName: "Resolution",
        icon: { .symbol(.menuBar("display.2", weight: .medium), fallbackTitle: "Res") },
        elements: { [weak self] in
            guard let self else { return [] }
            var elements: [MenuElement] = []

            let displays = self.store.displays
            if displays.isEmpty {
                elements.append(.info("No Displays Connected"))
                elements.append(.separator)
            }
            for display in displays {
                elements.append(.info(display.name,
                                      symbolName: Self.symbolName(for: display),
                                      color: .secondaryLabelColor,
                                      font: .boldSystemFont(ofSize: NSFont.systemFontSize)))
                elements.append(.submenu(id: "res.\(display.id)", title: "    Resolution") {
                    self.resolutionElements(for: display.id)
                })
                elements.append(.submenu(id: "hz.\(display.id)", title: "    Refresh Rate") {
                    self.refreshRateElements(for: display.id)
                })
                elements.append(.separator)
            }

            elements.append(.action(id: "settings", title: "Settings…", key: ",") {
                self.openSettings()
            })
            elements.append(.action(id: "displaySettings", title: "Display Settings…", key: "/") {
                NSWorkspace.shared.open(Self.displaySettingsURL)
                self.log("Opening System Settings → Displays.")
            })
            elements.append(.separator)
            elements.append(.about(title: "About Resolution…") {
                self.showAboutPanel()
            })
            elements.append(.separator)
            elements.append(.quit(title: "Quit Resolution"))
            return elements
        },
        willOpen: { [weak self] in self?.store.reconcile() },
        prewarmSymbols: Self.headerSymbols.map {
            SymbolSpec(name: $0, pointSize: NSFont.systemFontSize, weight: .regular)
        }))

    // MARK: - Lifecycle

    /// Installs the status item. Call once, at launch.
    func install() { menu.install() }

    /// Opens the Settings window. The app stays `.accessory`; `open()` activates the app
    /// to bring the window forward.
    private func openSettings() {
        guard !isTerminating else {
            log("Skipping openSettings: the application is terminating.")
            return
        }
        settings.open()
        log("Opening Settings window.")
    }

    /// Shows the standard About panel, which renders Credits.html from the bundle.
    func showAboutPanel() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
        log("Opening the standard About panel.")
    }

    // MARK: – Termination

    private var isTerminating = false

    /// Synchronous teardown: closes the Settings window and pulls the status item before
    /// the process unwinds.
    func prepareForTerminationSynchronously() {
        isTerminating = true
        menu.markTerminating()
        if let settings = _settings, settings.visibleWindow != nil {
            settings.close()
            // Lets AppKit process the close so the window disappears before exit.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        menu.prepareForTerminationSynchronously()
        log("ResolutionMenu torn down.")
    }
}

// MARK: - Submenu Builders

private extension ResolutionMenu {

    /// The Resolution submenu: one radio-style row per resolution, the current one checked,
    /// the display's default marked. The HiDPI-only preference is read here, on expansion.
    func resolutionElements(for id: CGDirectDisplayID) -> [MenuElement] {
        guard let display = store.display(id: id) else {
            return [.info("Display Disconnected")]
        }
        let resolutions = display.resolutions(hiDPIOnly: Preferences.onlyShowHiDPI)
        guard !resolutions.isEmpty else {
            return [.info("No Resolutions Available")]
        }
        let current = display.currentMode?.resolution

        return resolutions.map { resolution in
            let title = display.isDefault(resolution)
                ? "\(resolution.title) – Default"
                : resolution.title
            return .toggle(id: "res.\(id).\(resolution.width)x\(resolution.height).\(resolution.isHiDPI)",
                           title: title,
                           isOn: { resolution == current },
                           // Radio behavior: vetoes the uncheck of the current row.
                           willChange: { $0 },
                           setOn: { _ in
                               guard let mode = display.mode(for: resolution) else { return }
                               self.apply(mode, to: id)
                           })
        }
    }

    /// The Refresh Rate submenu: the rates at the display's current resolution, highest
    /// first, the current one checked.
    func refreshRateElements(for id: CGDirectDisplayID) -> [MenuElement] {
        guard let display = store.display(id: id) else {
            return [.info("Display Disconnected")]
        }
        guard let current = display.currentMode else {
            return [.info("Current Mode Unknown")]
        }
        let rates = display.refreshRates(for: current.resolution)
        guard !rates.isEmpty else {
            return [.info("Refresh Rate Not Reported")]
        }

        return rates.map { rate in
            .toggle(id: "hz.\(id).\(rate)",
                    title: DisplayMode.formatRefreshRate(rate),
                    isOn: { rate == current.roundedRefreshRate },
                    willChange: { $0 },
                    setOn: { _ in
                        guard let mode = display.mode(for: current.resolution, refreshRate: rate)
                        else { return }
                        self.apply(mode, to: id)
                    })
        }
    }

    /// Applies `mode` and reconciles the store immediately, so a menu reopened before the
    /// reconfiguration callback lands already shows the change.
    func apply(_ mode: DisplayMode, to id: CGDirectDisplayID) {
        if let current = store.display(id: id)?.currentMode, current == mode { return }
        do {
            try Setter.apply(mode, to: id)
        } catch {
            log("Failed to set display \(id) to \(mode.resolution.title) @ \(DisplayMode.formatRefreshRate(mode.refreshRate)): \(error.localizedDescription)",
                level: .error)
        }
        store.reconcile()
    }
}

// MARK: - Display Header Glyphs

private extension ResolutionMenu {

    static let headerSymbols = ["macbook", "desktopcomputer", "display", "tv"]

    /// The host's form factor for the built-in panel, a TV for anything that names itself
    /// one, a plain display otherwise.
    static func symbolName(for display: DisplayInfo) -> String {
        if display.isBuiltin {
            return hostHasInternalBattery ? "macbook" : "desktopcomputer"
        }
        let name = display.name.lowercased()
        if name.contains("tv") || name.contains("television") {
            return "tv"
        }
        return "display"
    }

    /// Whether the host carries an internal battery, i.e. is a MacBook. Model identifiers
    /// aren't usable for this: Apple Silicon Macs from 2022 on report "Mac15,10"-style
    /// names with no form factor in them. Evaluated once; the hardware can't change under
    /// a running process.
    static let hostHasInternalBattery: Bool = {
        guard let info = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = unsafe IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            guard let description = unsafe IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}
