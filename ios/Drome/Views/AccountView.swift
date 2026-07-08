//
//  AccountView.swift
//  Drome
//
//  The account & sync screen, reached from Settings. Accounts are opt-in and
//  needed ONLY for sync/groups — the whole app works signed out, so this screen
//  never nags. Signed out: one honest line + Sign in with Apple (plus a DEBUG
//  dev field for local testing). Signed in: the account label, a quiet
//  "Last synced" row, sign out, and delete account (destructive, confirmed).
//  A conflict banner appears when this phone's challenge was archived in favour
//  of the account's existing one. Tokens/design per DesignSystem; no hex
//  literals; no shame, no dark patterns.
//

import AuthenticationServices
import SwiftUI

@MainActor
struct AccountView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var deleteConfirmPresented = false
    @State private var emailInput = ""
    @State private var codeInput = ""
    #if DEBUG
    @State private var devKey = "alice"
    #endif

    var body: some View {
        Form {
            if appModel.signedIn {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .tint(Color.dromeClay)
        .scrollContentBackground(.hidden)
        .background(Color.dromeSand)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        // Account/auth failures get their OWN alert with a fitting title —
        // never the log-write "That didn't save" copy (wrong for sign-in /
        // delete / offline).
        .alert(
            appModel.accountAlert?.title ?? "",
            isPresented: Binding(
                get: { appModel.accountAlert != nil },
                set: { if !$0 { appModel.clearAccountAlert() } }
            ),
            presenting: appModel.accountAlert
        ) { _ in
            Button("OK", role: .cancel) { appModel.clearAccountAlert() }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOutContent: some View {
        Section {
            Text("Sync your challenge across devices and join friend groups. Free during beta.")
                .font(.subheadline)
                .foregroundStyle(Color.dromeInk.opacity(0.75))
                .padding(.vertical, DromeSpacing.xs)
        } header: {
            sectionHeader("Why sign in")
        } footer: {
            Text("You can keep using Drome without an account — sign-in only adds sync and groups.")
        }
        .listRowBackground(rowBackground)

        Section {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
                request.nonce = appModel.appleSignInRequestNonce()
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, DromeSpacing.xs)
        }
        .listRowBackground(Color.clear)

        emailSignInSection

        #if DEBUG
        devSignInSection
        #endif
    }

    /// Passwordless email six-digit OTP. Two steps in one section: enter an
    /// email to be sent a code, then enter the code. `awaitingCodeForEmail`
    /// (on AppModel) decides which step shows.
    @ViewBuilder
    private var emailSignInSection: some View {
        Section {
            if let email = appModel.awaitingCodeForEmail {
                Text("Enter the 6-digit code sent to \(email).")
                    .font(.footnote)
                    .foregroundStyle(Color.dromeInk.opacity(0.7))
                    .padding(.vertical, DromeSpacing.xs)
                HStack(spacing: DromeSpacing.s) {
                    TextField("6-digit code", text: $codeInput)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .monospacedDigit()
                        .frame(minHeight: DromeSpacing.tapTarget)
                    Button("Verify") { appModel.verifyEmailCode(codeInput) }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                        .disabled(codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Use a different email") {
                    codeInput = ""
                    appModel.cancelEmailSignIn()
                }
                .font(.subheadline)
                .foregroundStyle(Color.dromeInk.opacity(0.6))
                .frame(minHeight: DromeSpacing.tapTarget)
            } else {
                HStack(spacing: DromeSpacing.s) {
                    TextField("you@example.com", text: $emailInput)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: DromeSpacing.tapTarget)
                    Button("Email code") { appModel.requestEmailCode(emailInput) }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                        .disabled(emailInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            sectionHeader("Or sign in with email")
        } footer: {
            Text(appModel.awaitingCodeForEmail == nil
                 ? "We'll email you a six-digit code — no password."
                 : "The code expires in 10 minutes.")
        }
        .listRowBackground(rowBackground)
    }

    #if DEBUG
    private var devSignInSection: some View {
        Section {
            HStack(spacing: DromeSpacing.s) {
                TextField("Account key", text: $devKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: DromeSpacing.tapTarget)
                Button("Dev sign in") {
                    appModel.signInDev(key: devKey)
                }
                .font(.headline.weight(.black))
                .foregroundStyle(Color.dromeClay)
            }
        } header: {
            sectionHeader("Local dev sign-in")
        } footer: {
            Text("DEBUG only. Requires the local server running with DROME_DEV_AUTH=1.")
        }
        .listRowBackground(rowBackground)
    }
    #endif

    // MARK: - Signed in

    @ViewBuilder
    private var signedInContent: some View {
        if appModel.pendingConflict {
            conflictBanner
        }

        Section {
            LabeledContent("Account") {
                Text(appModel.accountLabel ?? "Signed in")
                    .foregroundStyle(Color.dromeInk.opacity(0.75))
            }
            .frame(minHeight: DromeSpacing.tapTarget)

            HStack {
                Text("Sync")
                Spacer()
                syncStatusLabel
            }
            .frame(minHeight: DromeSpacing.tapTarget)

            if let entitlementLabel {
                LabeledContent("Plan") {
                    Text(entitlementLabel)
                        .foregroundStyle(Color.dromeInk.opacity(0.75))
                }
                .frame(minHeight: DromeSpacing.tapTarget)
            }
        } header: {
            sectionHeader("Signed in")
        }
        .listRowBackground(rowBackground)

        Section {
            Button("Sign out") {
                appModel.signOut()
            }
            .foregroundStyle(Color.dromeInk)
            .frame(minHeight: DromeSpacing.tapTarget)

            Button("Delete account…", role: .destructive) {
                deleteConfirmPresented = true
            }
            .foregroundStyle(Color.dromeMiss)
            .frame(minHeight: DromeSpacing.tapTarget)
        } footer: {
            Text("Signing out keeps everything on this phone — it only stops syncing. Deleting removes your account and its synced data from the server; this phone's data stays.")
        }
        .listRowBackground(rowBackground)
        .confirmationDialog(
            "Delete your account?",
            isPresented: $deleteConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                appModel.deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your account and its synced data from the server. Your challenge and history on this phone are not deleted.")
        }
    }

    private var conflictBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                Text("This phone's challenge was archived")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.dromeInk)
                Text("Your account already has an active challenge, so this phone adopted it. Nothing was lost — the archived challenge's days are kept.")
                    .font(.footnote)
                    .foregroundStyle(Color.dromeInk.opacity(0.75))
                Button("Got it") {
                    appModel.syncEngine?.pendingConflict = false
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.dromeClay)
                .padding(.top, DromeSpacing.xs)
            }
            .padding(.vertical, DromeSpacing.xs)
        }
        .listRowBackground(Color.dromeCamel.opacity(0.14))
    }

    // MARK: - Status helpers

    @ViewBuilder
    private var syncStatusLabel: some View {
        switch appModel.syncStatus {
        case .syncing:
            Text("Syncing…")
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        case .error(let message):
            Text(message)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color.dromeMiss.opacity(0.9))
        case .idle:
            Text(lastSyncedCaption)
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
    }

    private var lastSyncedCaption: String {
        guard let date = appModel.lastSyncedAt else { return "Not synced yet" }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "Last synced \(relative)"
    }

    private var entitlementLabel: String? {
        guard let entitlement = appModel.entitlement else { return nil }
        if entitlement.betaAllEntitled { return "Free during beta" }
        return entitlement.entitled ? "Active" : "Sync paused"
    }

    // MARK: - Sign in with Apple plumbing (AS types stay in this view)

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appModel.appleSignInFailed("Apple didn't return an identity token. Please try again.")
                return
            }
            appModel.completeAppleSignIn(identityToken: token, label: appleLabel(credential))
        case .failure(let error):
            // A user cancel isn't worth an alert.
            if (error as? ASAuthorizationError)?.code == .canceled {
                appModel.appleSignInFailed(nil)
            } else {
                appModel.appleSignInFailed("Sign in with Apple didn't complete. Please try again.")
            }
        }
    }

    /// A friendly label from the first-authorization credential (email/name are
    /// only present the very first time; fall back to a generic label).
    private func appleLabel(_ credential: ASAuthorizationAppleIDCredential) -> String? {
        if let email = credential.email { return email }
        if let given = credential.fullName?.givenName, !given.isEmpty { return given }
        return "Apple account"
    }

    // MARK: - Styling

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Previews

#Preview("Signed out") {
    NavigationStack {
        AccountView()
    }
    .environment(AppModel())
}
