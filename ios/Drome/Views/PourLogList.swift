//
//  PourLogList.swift
//  Drome
//
//  Compact, removable ledger of one day's water pours, shared by WaterView
//  ("TODAY'S POURS") and the yesterday sheet ("YESTERDAY'S POURS"). Rows stay
//  short and quiet — a ledger, not a feature.
//
//  Ordering: entries arrive logged_at-ascending (the core contract) and are
//  displayed newest-first, so the pour just logged — the likeliest removal
//  target — is always the visible top row and never hidden behind the inner
//  scroll. Capped at three visible rows; longer days scroll inside the list.
//

import SwiftUI

struct PourLogList: View {

    /// Row height, exposed so hosts can size empty-state placeholders to match.
    static let rowHeight: CGFloat = 32
    private static let rowsVisible = 3

    /// The day's pours, logged_at-ascending as the client delivers them.
    let entries: [WaterLogEntry]

    /// Removal intent for a swiped row. Hosts revoke the event and reload
    /// their own copy of the log.
    let onRemove: (WaterLogEntry) -> Void

    var body: some View {
        List {
            ForEach(entries.reversed()) { entry in
                row(entry)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparatorTint(Color.dromeInk.opacity(0.12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Remove", role: .destructive) {
                            onRemove(entry)
                        }
                        .tint(Color.dromeMiss)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: Self.rowHeight * CGFloat(min(entries.count, Self.rowsVisible)))
        .scrollDisabled(entries.count <= Self.rowsVisible)
    }

    private func row(_ entry: WaterLogEntry) -> some View {
        HStack(spacing: DromeSpacing.s) {
            Text(timeText(entry))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk.opacity(0.55))
            if entry.retro {
                // Explicitly-dated pour (an "edit yesterday" add, or an
                // imported snapshot's dated event) — marked so the ledger is
                // honest about live logs vs. after-the-fact additions. The
                // copy is date-neutral on purpose: `retro` means "carried an
                // explicit effective date", whatever day this list shows, so
                // naming a specific day here could lie. Reachable in the
                // yesterday sheet's list (a "Met goal" add is backdated);
                // today's list only shows it for imported events dated today.
                Text("backdated")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(Color.dromeInk.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.dromeInk.opacity(0.08), in: Capsule())
            }
            Spacer()
            Text("+\(oz(entry.ml)) oz")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(oz(entry.ml)) ounces at \(timeText(entry))\(entry.retro ? ", logged retroactively" : "")"
        )
        .accessibilityHint("Swipe up or down with one finger to remove")
    }

    /// Wall-clock time of the pour as the user saw it when logging (the
    /// entry's own UTC offset, not necessarily the current zone).
    private func timeText(_ entry: WaterLogEntry) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = TimeZone(secondsFromGMT: entry.tzOffsetSecs) ?? .current
        return entry.loggedAt.formatted(style)
    }
}

/// Nearest ounce (storage is ml; display is fl oz).
private func oz(_ ml: Int64) -> Int {
    max(0, Int(WaterUnits.flOz(fromMl: ml).rounded()))
}

// MARK: - Previews

#Preview("Four pours, one backdated") {
    let tz = TimeZone.current.secondsFromGMT()
    VStack {
        PourLogList(
            entries: [
                WaterLogEntry(id: "a", ml: 946, loggedAt: Date().addingTimeInterval(-6 * 3600), tzOffsetSecs: tz, retro: false),
                WaterLogEntry(id: "b", ml: 350, loggedAt: Date().addingTimeInterval(-4 * 3600), tzOffsetSecs: tz, retro: false),
                WaterLogEntry(id: "c", ml: 946, loggedAt: Date().addingTimeInterval(-2 * 3600), tzOffsetSecs: tz, retro: false),
                WaterLogEntry(id: "d", ml: 500, loggedAt: Date(), tzOffsetSecs: tz, retro: true),
            ],
            onRemove: { _ in }
        )
        .padding(DromeSpacing.m)
    }
    .background(Color.dromeSand)
}
