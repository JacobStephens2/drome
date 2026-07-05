//
//  ResetSheet.swift
//  Drome
//
//  The app's ONE destructive flow: reset everything back to the first
//  screen. Safety outranks elegance here — the sheet states exactly what is
//  deleted (with the real number), says plainly that progress photos are
//  never inside a backup, ramps the user toward an export first, and
//  requires TWO distinct confirmation acts (the destructive button, then
//  a "Last check" alert). The wipe itself never runs from this sheet: the
//  confirm ARMS the reset (via the presenter's binding) and dismisses, and
//  the presenting SettingsView performs `AppModel.resetApp()` in its
//  onDismiss — after the sheet is fully down — so AppFlowView's full-screen
//  swap to onboarding can never strand a presented sheet. Every other exit
//  (Cancel, swipe-down, a fresh presentation) explicitly DISARMS, so no
//  cancel affordance can ever double as the trigger. Copy is honest and
//  calm: no dark patterns, no guilt; the export nudge informs, never blocks.
//

import SwiftUI

@MainActor
struct ResetSheet: View {

    private let client: any DromeCoreClient
    /// The presenter's latch: true = run the wipe in its onDismiss. Set only
    /// by the "Last check" confirmation; cleared on every appearance and by
    /// Cancel, so the armed state can never leak across presentations.
    @Binding private var armed: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastBackupAt") private var lastBackupAt: Double = 0

    /// The honest N for "all N days of logged history": the UNCLAMPED day
    /// count — max of the display index and `todayRawDayIndex`. The display
    /// index clamps to lengthDays ("Day 75 of 75"), but days lived past the
    /// end still attribute and hold live events, so a day-90 reset must say
    /// 90, not 75: understating a deletion is the dangerous direction.
    /// Deliberately NOT daysCompleteCount — incomplete days still hold
    /// logged history. The residual overstatement (days with nothing
    /// logged) is the safe direction for a deletion warning.
    @State private var daysLogged: Int?

    @State private var exportDocument: TextExportDocument?
    @State private var exporterPresented = false
    /// Set when an export completes IN THIS SHEET. The "Last check" alert
    /// drops its backup warning once it's true — it informs, it never blocks.
    @State private var exportedThisSession = false
    @State private var lastCheckPresented = false
    @State private var errorMessage: String?

    init(client: any DromeCoreClient, armed: Binding<Bool>) {
        self.client = client
        self._armed = armed
    }

    var body: some View {
        // ScrollView so every act stays reachable at accessibility type
        // sizes and the .medium detent: without it the Cancel button and
        // restore footer clip off-screen while "Delete everything" stays
        // visible — exactly the wrong control to strand a user on.
        ScrollView {
            VStack(alignment: .leading, spacing: DromeSpacing.l) {
                VStack(alignment: .leading, spacing: DromeSpacing.s) {
                    Text("Reset Drome?")
                        .dromeTitle()
                    Text(deletionCopy)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.dromeInk)
                }

                Button(action: beginExport) {
                    Label("Export a backup first", systemImage: "externaldrive.badge.checkmark")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.dromeClay)
                .accessibilityHint(
                    "Saves your logged history as a file before anything is deleted. "
                        + "Progress photos can't be included."
                )

                if exportedThisSession {
                    Label("Backup saved.", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dromeDone)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Button(role: .destructive) {
                    lastCheckPresented = true
                } label: {
                    Text("Delete everything")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                }
                .buttonStyle(.bordered)
                .tint(Color.dromeMiss)
                .accessibilityLabel("Delete everything")
                .accessibilityHint(
                    "Permanently deletes your challenge, \(daysPhrase), and every progress photo "
                        + "on this phone. There is no undo. A final confirmation follows."
                )

                Button {
                    armed = false
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                }
                .buttonStyle(.bordered)
                .tint(Color.dromeInk)
                .accessibilityLabel("Cancel, keep everything")

                Text("After a reset you can restore this backup from the first screen. "
                    + "Backups never include progress photos.")
                    .font(.footnote)
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(DromeSpacing.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.dromeSand)
        .presentationDetents([.medium, .large])
        .onAppear {
            // Every presentation starts DISARMED — a stale latch from any
            // earlier path must never turn a cancel into the wipe trigger.
            armed = false
            load()
        }
        .fileExporter(
            isPresented: $exporterPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: dromeExportFilename(prefix: "drome-backup")
        ) { result in
            handleExport(result)
        }
        // Second, distinct confirmation act. The wipe is armed only here.
        .alert("Last check", isPresented: $lastCheckPresented) {
            Button("Delete everything", role: .destructive) {
                armed = true
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(lastCheckMessage)
        }
        .alert("Couldn't export", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Copy (honest, calm, with the real number)

    private var daysPhrase: String {
        guard let n = daysLogged else { return "your logged history" }
        return n == 1 ? "the 1 day of logged history" : "all \(n) days of logged history"
    }

    private var deletionCopy: String {
        "Your challenge, \(daysPhrase), and every progress photo on this phone. "
            + "There is no undo. Photos are never part of a backup — a reset "
            + "deletes them for good."
    }

    private var lastCheckMessage: String {
        var text: String
        if let n = daysLogged {
            text = n == 1
                ? "1 day and every progress photo will be permanently deleted."
                : "\(n) days and every progress photo will be permanently deleted."
        } else {
            text = "Everything, including every progress photo, will be permanently deleted."
        }
        if let warning = backupWarning {
            text += " \(warning)"
        }
        return text
    }

    /// The backup line of the "Last check" alert, derived from the SHARED
    /// `lastBackupAt` bookkeeping so it is never false: a user who backed up
    /// a minute ago in Settings > Export & backup has a backup, whether or
    /// not this sheet made it. Omitted entirely after an in-sheet export;
    /// otherwise it states the real gap, conservatively.
    private var backupWarning: String? {
        if exportedThisSession { return nil }
        guard lastBackupAt > 0 else { return "You haven't exported a backup." }
        let when = Date(timeIntervalSince1970: lastBackupAt)
            .formatted(.relative(presentation: .named))
        return "Your last backup was \(when) — anything logged since then isn't saved."
    }

    // MARK: Data & export (same path as ExportBackupView, reused not copied)

    private func load() {
        guard let summary = try? client.summary() else { return }
        daysLogged = max(summary.todayDayIndex, summary.todayRawDayIndex)
    }

    private func beginExport() {
        do {
            exportDocument = TextExportDocument(text: try client.exportJson())
            exporterPresented = true
        } catch {
            errorMessage = exportErrorText(error)
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportedThisSession = true
            // The exported JSON is a full snapshot — a real backup. Keep the
            // bookkeeping honest even if the user then cancels the reset.
            lastBackupAt = Date().timeIntervalSince1970
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        exportDocument = nil
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

// MARK: - Previews

#Preview("Reset sheet") {
    Color.dromeSand
        .sheet(isPresented: .constant(true)) {
            ResetSheet(client: MockDromeCore(), armed: .constant(false))
        }
}

#Preview("Reset sheet — dark") {
    Color.dromeSand
        .sheet(isPresented: .constant(true)) {
            ResetSheet(client: MockDromeCore(), armed: .constant(false))
        }
        .preferredColorScheme(.dark)
}
