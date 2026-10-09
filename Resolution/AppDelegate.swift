// MARK: – AppDelegate.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Entry point (@main) and AppDelegate for a menu-bar-only accessory app:
// bootstraps logging, the display store, the status menu and the watcher, and runs the
// controlled shutdown.

import Cocoa

// Plain AppKit entry point, as in Toggler. A SwiftUI `App` needs at least one Scene, and
// an empty WindowGroup is not free: closing its window at launch only works once, because
// SwiftUI re-creates the 0×0 window on every reopen event (launching the app again while
// it is running, e.g. from Xcode, Finder or the Dock), and Mission Control then lists
// that invisible window under "Resolution". With no Scene there is nothing to re-create.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AppDelegate]"

    // MARK: - Entry point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    let store = DisplayStore()

    private var menuController: ResolutionMenu?
    private var watcher: Watcher?

    private var isTerminating = false
    private var hasRepliedToTerminate = false

    private let appVersionBuild: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // prepareLogDirectory() reads Preferences.loggingEnabled, so the defaults and the
        // logger must be in place first.
        Preferences.ensureDefaultsRegistered()
        Logger.bootstrap(.init(fileName: "Resolution.log",
                               destination: .containerLibraryLogs,
                               isEnabled: { Preferences.loggingEnabled }))
        Logger.prepareLogDirectory()
        log("Resolution application \(appVersionBuild) launched.")

        // Enumerate before installing, so the first menu open already has every display.
        store.refresh()
        let menuController = ResolutionMenu(store: store)
        menuController.install()
        self.menuController = menuController

        let watcher = Watcher { [weak self] in self?.store.refresh() }
        watcher.start()
        self.watcher = watcher
    }

    // Deferred with '.terminateLater' so the logger's final flush can be awaited, which
    // makes the termination lines durable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second Quit while the first is in flight must not run the teardown again.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        log("applicationShouldTerminate: Beginning controlled shutdown.")

        performTeardown()
        log("Resolution application \(appVersionBuild) terminating.")

        // Whichever finishes first replies: a stalled flush must not leave a menu-bar app
        // refusing to quit with no UI to say why. Both tasks are main-actor-isolated, so
        // replyToTerminateOnce() needs no further synchronization.
        Task { @MainActor [weak self] in
            await Logger.shutdownLoggingAwaiting()
            self?.replyToTerminateOnce()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.replyToTerminateOnce()
        }
        return .terminateLater
    }

    // NSApp.reply(toApplicationShouldTerminate:) must be called exactly once.
    private func replyToTerminateOnce() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Safety net for termination paths that bypass applicationShouldTerminate.
    func applicationWillTerminate(_ notification: Notification) {
        performTeardown()
    }

    // Idempotent. The watcher is stopped explicitly because its C callback reaches it
    // through a static reference; that must be cleared before the last reference drops.
    private func performTeardown() {
        watcher?.stop()
        watcher = nil

        menuController?.prepareForTerminationSynchronously()
        menuController = nil
    }

    // MARK: – External helper

    // Target of the "About Resolution" item in the temporary main menu SettingsKit installs
    // while the Settings window is open.
    @objc func showAboutPanel(_ sender: Any?) {
        menuController?.showAboutPanel()
    }
}
