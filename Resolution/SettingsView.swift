// MARK: – SettingsView.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The General settings tab, built from the shared SettingsKit primitives.

import SwiftUI

// MARK: – General Tab

@MainActor
struct GeneralTabView: View, Loggable {
    nonisolated static let logTag = "[GeneralTabView]"

    // @AppStorage rather than a preference setter so the per-toggle log line can be
    // emitted from onChange. Both take effect on the next menu open.
    @AppStorage(Preferences.onlyShowHiDPIKey)
        private var onlyShowHiDPI: Bool = false
    @AppStorage(Preferences.showAllModesKey)
        private var showAllModes: Bool = false

    var body: some View {
        SettingsPage {
            LaunchAtLoginToggle()

            Divider()

            SettingsDescribedToggle(
                "Hide non-HiDPI resolution options",
                description: "This does not apply to displays which do not support any HiDPI modes. The currently-selected resolution is always listed.",
                isOn: $onlyShowHiDPI)
                .onChange(of: onlyShowHiDPI) { _, newValue in
                    Self.log("Only show HiDPI resolutions \(newValue ? "enabled" : "disabled")")
                }

            SettingsDescribedToggle(
                "Show low resolution options",
                description: "Include in the list resolutions that macOS reports as not suitable for use. Selecting one of these is not advised.",
                isOn: $showAllModes)
                .onChange(of: showAllModes) { _, newValue in
                    Self.log("Show all display modes \(newValue ? "enabled" : "disabled")")
                }

            Divider()

            SettingsLoggingSection(loggingEnabledKey: Preferences.loggingEnabledKey) { newValue in
                // Already committed by the section's own binding; this keeps the write
                // routed through Preferences. Logging and shutdown handling are the kit's.
                Preferences.loggingEnabled = newValue
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
