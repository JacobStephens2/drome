//
//  ExportBackupView.swift
//  Drome
//
//  Export (JSON / CSV via fileExporter), backup (JSON snapshot with
//  last-backup bookkeeping in @AppStorage("lastBackupAt")), and restore
//  (fileImporter → importJson, which only works into a fresh app).
//  Exports and backups are the only data that ever leaves the device,
//  and only where the user sends them.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export document

private struct TextExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText, .plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - ExportBackupView

@MainActor
struct ExportBackupView: View {

    private enum ExportKind {
        case json
        case csv
        case backup
    }

    private let client: any DromeCoreClient

    @Environment(AppModel.self) private var appModel: AppModel?
    @AppStorage("lastBackupAt") private var lastBackupAt: Double = 0

    @State private var exportKind: ExportKind = .json
    @State private var exportDocument: TextExportDocument?
    @State private var exporterPresented = false
    @State private var importerPresented = false
    @State private var pendingRestoreJson: String?
    @State private var restoreConfirmPresented = false
    @State private var restoreSucceeded = false
    @State private var errorTitle = "Something went wrong"
    @State private var errorMessage: String?

    init(client: any DromeCoreClient) {
        self.client = client
    }

    var body: some View {
        Form {
            exportSection
            backupSection
            restoreSection
        }
        .tint(Color.dromeClay)
        .scrollContentBackground(.hidden)
        .background(Color.dromeSand)
        .navigationTitle("Export & Backup")
        .fileExporter(
            isPresented: $exporterPresented,
            document: exportDocument,
            contentType: exportKind == .csv ? .commaSeparatedText : .json,
            defaultFilename: defaultFilename
        ) { result in
            handleExport(result)
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.json]
        ) { result in
            handleImportPick(result)
        }
        .sheet(isPresented: $restoreConfirmPresented) {
            restoreConfirmSheet
        }
        .alert(errorTitle, isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Backup restored", isPresented: $restoreSucceeded) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your history is back on this phone.")
        }
    }

    // MARK: Sections

    private var exportSection: some View {
        Section {
            Button {
                beginExport(.json)
            } label: {
                Label("Export JSON (full history)", systemImage: "doc.text")
            }
            .frame(minHeight: DromeSpacing.tapTarget)

            Button {
                beginExport(.csv)
            } label: {
                Label("Export CSV (spreadsheet)", systemImage: "tablecells")
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Export")
        } footer: {
            Text("Your data never leaves this device except when you export or share.")
        }
        .listRowBackground(rowBackground)
    }

    private var backupSection: some View {
        Section {
            HStack(spacing: DromeSpacing.s) {
                if backupStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.dromeMiss)
                }
                VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                    Text(lastBackupHeadline)
                        .font(.headline.weight(.black))
                        .monospacedDigit()
                        .foregroundStyle(backupStale ? Color.dromeMiss : Color.dromeInk)
                    Text(lastBackupDetail)
                        .font(.footnote)
                        .foregroundStyle(backupStale ? Color.dromeMiss.opacity(0.9) : Color.dromeInk.opacity(0.6))
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            .accessibilityElement(children: .combine)
            .listRowBackground(backupStale ? Color.dromeMiss.opacity(0.12) : rowBackground)

            Button {
                beginExport(.backup)
            } label: {
                Label("Back up now", systemImage: "externaldrive.badge.checkmark")
                    .fontWeight(.bold)
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            .listRowBackground(rowBackground)
        } header: {
            sectionHeader("Backup")
        } footer: {
            Text("A backup on this phone doesn't survive losing the phone — save to iCloud Drive.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                importerPresented = true
            } label: {
                Label("Restore from backup", systemImage: "clock.arrow.circlepath")
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Restore")
        } footer: {
            Text("Restore loads a JSON backup into a fresh app — it won't run over an existing challenge.")
        }
        .listRowBackground(rowBackground)
    }

    private var restoreConfirmSheet: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.l) {
            Text("Restore from backup")
                .dromeTitle()
            Text("This loads the full history snapshot from your backup file. Restore only works into a fresh app with no active challenge — if one is already running on this phone, nothing will change.")
                .foregroundStyle(Color.dromeInk)

            Spacer(minLength: 0)

            Button {
                performRestore()
            } label: {
                Text("Restore")
                    .font(.headline.weight(.black))
                    .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.dromeClay)

            Button {
                pendingRestoreJson = nil
                restoreConfirmPresented = false
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
            }
            .buttonStyle(.bordered)
            .tint(Color.dromeInk)
        }
        .padding(DromeSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dromeSand)
        .presentationDetents([.medium])
    }

    // MARK: Styling helpers

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }

    // MARK: Backup status

    private var lastBackupDate: Date? {
        lastBackupAt > 0 ? Date(timeIntervalSince1970: lastBackupAt) : nil
    }

    private var backupStale: Bool {
        guard let lastBackupDate else { return true }
        return Date().timeIntervalSince(lastBackupDate) > 7 * 24 * 3600
    }

    private var lastBackupHeadline: String {
        guard let lastBackupDate else { return "Never backed up" }
        return "Last backed up: \(lastBackupDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private var lastBackupDetail: String {
        guard let lastBackupDate else {
            return "Your history lives only on this phone."
        }
        let days = Int(Date().timeIntervalSince(lastBackupDate) / 86400)
        if backupStale {
            return "\(days) days ago — back up now."
        }
        switch days {
        case 0: return "Today."
        case 1: return "Yesterday."
        default: return "\(days) days ago."
        }
    }

    // MARK: Export & backup actions

    private func beginExport(_ kind: ExportKind) {
        do {
            let content: String
            switch kind {
            case .json, .backup:
                content = try client.exportJson()
            case .csv:
                content = try client.exportCsv()
            }
            exportKind = kind
            exportDocument = TextExportDocument(text: content)
            exporterPresented = true
        } catch {
            presentError("Couldn't export", exportErrorText(error))
        }
    }

    /// fileExporter appends the extension for the content type, yielding
    /// drome-export-YYYY-MM-DD.json / .csv and drome-backup-YYYY-MM-DD.json.
    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: Date())
        switch exportKind {
        case .json, .csv: return "drome-export-\(stamp)"
        case .backup: return "drome-backup-\(stamp)"
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if exportKind == .backup {
                lastBackupAt = Date().timeIntervalSince1970
            }
        case .failure(let error):
            presentError("Couldn't save the file", error.localizedDescription)
        }
        exportDocument = nil
    }

    // MARK: Restore actions

    private func handleImportPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            do {
                pendingRestoreJson = try String(contentsOf: url, encoding: .utf8)
                restoreConfirmPresented = true
            } catch {
                presentError("Couldn't read that file", error.localizedDescription)
            }
        case .failure(let error):
            presentError("Couldn't open the file", error.localizedDescription)
        }
    }

    private func performRestore() {
        restoreConfirmPresented = false
        guard let snapshot = pendingRestoreJson else { return }
        pendingRestoreJson = nil

        do {
            try client.importJson(snapshot)
            appModel?.refresh()
            restoreSucceeded = true
        } catch DromeError.challengeAlreadyActive {
            presentError(
                "Couldn't restore",
                "Restore only works into a fresh app, and this phone already has an active challenge. Nothing was changed."
            )
        } catch {
            presentError("Couldn't restore", exportErrorText(error))
        }
    }

    // MARK: Error plumbing

    private func presentError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

// MARK: - Errors

private func exportErrorText(_ error: Error) -> String {
    guard let dromeError = error as? DromeError else { return String(describing: error) }
    switch dromeError {
    case .noActiveChallenge: return "There's no active challenge on this phone."
    case .challengeAlreadyActive: return "A challenge is already active on this phone."
    case .invalidDate(let detail): return "Invalid date: \(detail)."
    case .invalidArgument(let detail): return detail
    case .notFound(let detail): return "Not found: \(detail)."
    case .taskNotRevocable(let detail): return "Nothing to un-mark: \(detail)."
    case .storage(let detail): return "Storage problem: \(detail)."
    }
}

// MARK: - Previews

#Preview("Export & Backup") {
    let core = MockDromeCore()
    NavigationStack {
        ExportBackupView(client: core)
    }
    .environment(AppModel(core: core))
}

#Preview("Export & Backup — dark") {
    let core = MockDromeCore()
    NavigationStack {
        ExportBackupView(client: core)
    }
    .environment(AppModel(core: core))
    .preferredColorScheme(.dark)
}
