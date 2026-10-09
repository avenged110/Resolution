// MARK: – Watcher.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reports display connect/disconnect/reconfiguration events, debounced, to a single
// main-actor handler.

import CoreGraphics
import Foundation

@MainActor
final class Watcher: Loggable {
    nonisolated static let logTag = "[Watcher]"

    /// Coalescing window for bursts of reconfiguration callbacks (a multi-head dock, an
    /// EDID refresh, the begin/end pair every reconfiguration produces).
    private static let debounceInterval: Duration = .milliseconds(150)

    /// The registered instance, reached from the C callback, which cannot capture. Weak:
    /// `stop()` unregisters before the watcher goes away.
    private static weak var current: Watcher?

    private let onChange: @MainActor () -> Void
    private var isRegistered = false
    private var debounceTask: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    // MARK: - Control

    /// Registers the reconfiguration callback. Idempotent.
    func start() {
        guard !isRegistered else { return }
        Self.current = self
        unsafe CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, nil)
        isRegistered = true
        log("Display reconfiguration callback registered.")
    }

    /// Unregisters the callback and drops any pending report. Idempotent. Called from the
    /// termination path — `deinit` is nonisolated and cannot do this safely.
    func stop() {
        guard isRegistered else { return }
        unsafe CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, nil)
        isRegistered = false
        debounceTask?.cancel()
        debounceTask = nil
        if Self.current === self { Self.current = nil }
        log("Display reconfiguration callback removed.")
    }

    // MARK: - Callback

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, _ in
        // Only the second callback of each begin/change pair describes the change.
        guard !flags.contains(.beginConfigurationFlag) else { return }

        // Delivered on the main thread (registered from the main run loop); the hop is a
        // fallback for any other delivery.
        if Thread.isMainThread {
            MainActor.assumeIsolated { current?.handle(display: display, flags: flags) }
        } else {
            Task { @MainActor in current?.handle(display: display, flags: flags) }
        }
    }

    private func handle(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        log("Reconfiguration: display \(display), flags 0x\(String(flags.rawValue, radix: 16)).")
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.onChange()
        }
    }
}
