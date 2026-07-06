//
//  DromeApp.swift
//  Drome
//
//  Composition root. Production client = LiveDromeCore over the shared
//  SQLite store (App Group container, Application Support fallback — see
//  DromeShared/SharedPaths.swift). If the store cannot open, the app shows
//  an honest blocking error screen; it NEVER falls back to the in-memory
//  mock — a user logging real days into a throwaway store is the one
//  unforgivable failure mode here. Previews keep MockDromeCore via
//  AppModel's default init.
//

import SwiftUI
import WidgetKit

@main
struct DromeApp: App {
    @State private var appModel: AppModel?
    private let storeOpenError: String?

    init() {
        do {
            let client = try LiveDromeCore(dbPath: SharedPaths.databasePath)
            #if DEBUG
            DromeDebugLaunch.seedIfRequested(client: client)
            #endif
            let model = AppModel(core: client)
            model.refresh()
            // Restore a persisted account session (opt-in; no-op when signed
            // out) so sync resumes across launches without re-authenticating.
            // Gated: server features stay dark in Release until drome-server is live.
            if FeatureFlags.serverFeatures {
                model.restoreAccountSession()
            }
            _appModel = State(initialValue: model)
            storeOpenError = nil
        } catch {
            _appModel = State(initialValue: nil)
            storeOpenError = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let appModel {
                AppFlowView()
                    .environment(appModel)
            } else {
                StoreOpenFailureView(detail: storeOpenError ?? "Unknown storage error")
            }
        }
    }
}

// MARK: - Flow gate (onboarding vs. the running app)

/// No active challenge → onboarding (which hands past starts to BackfillView
/// itself); otherwise the three-tab RootView. Onboarding's `onComplete`
/// refreshes the model, and the fresh `challenge` flips this view over.
private struct AppFlowView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.challenge != nil {
            RootView()
        } else {
            OnboardingView(client: appModel.client) {
                // Onboarding writes (createChallenge, presets, backfill) go
                // through the client directly; catch the widget up here.
                appModel.refresh()
                WidgetCenter.shared.reloadAllTimelines()
            }
            // RootView (and its shared error alert) is gone once the
            // challenge is nil, but one error can still exist here:
            // `resetApp()` wiped the store and then couldn't delete every
            // progress photo. That message must not vanish unseen — surface
            // it over onboarding.
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { appModel.lastErrorMessage != nil },
                    set: { if !$0 { appModel.clearLastError() } }
                )
            ) {
                Button("OK", role: .cancel) { appModel.clearLastError() }
            } message: {
                Text(appModel.lastErrorMessage ?? "")
            }
        }
    }
}

// MARK: - Blocking store-failure screen (never silently degrade to a mock)

private struct StoreOpenFailureView: View {
    let detail: String

    var body: some View {
        ZStack {
            Color.dromeSand.ignoresSafeArea()
            VStack(alignment: .leading, spacing: DromeSpacing.m) {
                Text("Drome couldn't open its data store")
                    .dromeTitle()
                Text("Your logged days are still on this device — nothing was lost or overwritten. Rather than risk starting over on a blank slate, Drome won't run until the store opens again.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.dromeInk)
                Text("Try force-quitting and reopening the app. If this keeps happening, free up storage space and try again.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.dromeInk.opacity(0.7))
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
                    .textSelection(.enabled)
            }
            .padding(DromeSpacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview("Store failure") {
    StoreOpenFailureView(detail: "storage(\"unable to open database file\")")
}
