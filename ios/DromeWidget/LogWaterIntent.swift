//
//  LogWaterIntent.swift
//  DromeWidget
//
//  Interactive-widget intent: logs one container preset of water through
//  the DromeCoreClient facade, then reloads timelines. ALWAYS routes
//  through the facade's chug check first — a widget has no room for the
//  confirmation dialog, so a warning means nothing is logged and the
//  timeline flips to the "Open Drome — pace check" state instead
//  (docs/ARCHITECTURE.md, "Water pacing & safety").
//

import AppIntents
import Foundation
import WidgetKit

struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource { "Log Water" }
    static var description: IntentDescription {
        IntentDescription("Adds water to today's Drome total.")
    }
    /// Quick-add must never pull the app forward.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Amount (ml)")
    var presetMl: Int

    @Parameter(title: "Preset name")
    var label: String

    init() {}

    init(presetMl: Int64, label: String) {
        self.presetMl = Int(presetMl)
        self.label = label
    }

    func perform() async throws -> some IntentResult {
        // Refresh in every exit path so the gauge (or pace-check state)
        // updates immediately.
        defer { WidgetCenter.shared.reloadAllTimelines() }

        let addMl = Int64(presetMl)
        guard addMl > 0 else { return .result() }

        // Store failed to open: log nothing (the widget shows "Open Drome").
        guard let client = WidgetCore.client else { return .result() }
        let check = try client.checkChug(addMl: addMl)
        if check.shouldWarn {
            // Anti-chug guard tripped: log NOTHING from the widget.
            // Confirming an over-limit pour requires the app's dialog.
            WidgetPaceCheck.setPending()
            return .result()
        }

        _ = try client.logWater(ml: addMl, effectiveDate: nil)
        WidgetPaceCheck.clear()
        return .result()
    }
}
