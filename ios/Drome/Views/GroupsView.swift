//
//  GroupsView.swift
//  Drome
//
//  Friend groups (docs/PHASE2.md "Groups"), reached from Settings. Groups are
//  opt-in and need an account, so a signed-out visitor sees a plain sign-in
//  prompt — never a broken screen. Signed in: the groups I belong to, plus
//  "Create a group" and "Join by code" actions.
//
//  This is accountability, not competition: no rankings, no leaderboards, no
//  streak-shaming. You each see everyone's day and current run, today's
//  checkboxes, and whether this week's extra is done — nothing more (the server
//  sends nothing more; see DromeAPI's group DTOs).
//

import SwiftUI

@MainActor
struct GroupsView: View {

    @Environment(AppModel.self) private var appModel

    @State private var createPresented = false
    @State private var joinPresented = false

    var body: some View {
        Group {
            if appModel.signedIn {
                signedInList
            } else {
                signedOutPrompt
            }
        }
        .tint(Color.dromeClay)
        .scrollContentBackground(.hidden)
        .background(Color.dromeSand)
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $createPresented) { CreateGroupSheet() }
        .sheet(isPresented: $joinPresented) { JoinGroupSheet() }
        .task {
            if appModel.signedIn { await appModel.refreshGroups() }
        }
    }

    // MARK: - Signed in

    private var signedInList: some View {
        Form {
            Section {
                if appModel.myGroups.isEmpty {
                    Text("You're not in any group yet. Create one and share the code, or join a friend's group by code.")
                        .font(.subheadline)
                        .foregroundStyle(Color.dromeInk.opacity(0.7))
                        .padding(.vertical, DromeSpacing.xs)
                } else {
                    ForEach(appModel.myGroups) { group in
                        NavigationLink {
                            GroupDetailView(groupId: group.id)
                        } label: {
                            groupRow(group)
                        }
                        .frame(minHeight: DromeSpacing.tapTarget)
                    }
                }
            } header: {
                sectionHeader("Your groups")
            }
            .listRowBackground(rowBackground)

            Section {
                Button {
                    createPresented = true
                } label: {
                    Label("Create a group", systemImage: "person.3")
                        .foregroundStyle(Color.dromeClay)
                }
                .frame(minHeight: DromeSpacing.tapTarget)

                Button {
                    joinPresented = true
                } label: {
                    Label("Join by code", systemImage: "number")
                        .foregroundStyle(Color.dromeClay)
                }
                .frame(minHeight: DromeSpacing.tapTarget)
            } footer: {
                Text("Groups are a quiet way to stay accountable together — you see each person's day and current run, today's checkboxes, and whether this week's extra is done. No rankings, no competition.")
            }
            .listRowBackground(rowBackground)
        }
    }

    private func groupRow(_ group: GroupSummary) -> some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text(group.name)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.dromeInk)
            Text(groupRowCaption(group))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
    }

    private func groupRowCaption(_ group: GroupSummary) -> String {
        let members = group.memberCount == 1 ? "1 member" : "\(group.memberCount) members"
        if let name = group.myDisplayName, !name.isEmpty {
            return "\(members) · you're \(name)"
        }
        return members
    }

    // MARK: - Signed out

    private var signedOutPrompt: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DromeSpacing.s) {
                    Text("Stay accountable with friends")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(Color.dromeInk)
                    Text("Sign in to create a group or join one by code. You'll each see everyone's day and current run, today's checkboxes, and whether this week's extra is done.")
                        .font(.subheadline)
                        .foregroundStyle(Color.dromeInk.opacity(0.75))
                }
                .padding(.vertical, DromeSpacing.xs)
            }
            .listRowBackground(rowBackground)

            Section {
                NavigationLink {
                    AccountView()
                } label: {
                    Label("Sign in to sync", systemImage: "person.crop.circle")
                        .foregroundStyle(Color.dromeClay)
                }
                .frame(minHeight: DromeSpacing.tapTarget)
            } footer: {
                Text("You can keep using Drome without an account — groups just need one so friends can find you.")
            }
            .listRowBackground(rowBackground)
        }
    }

    // MARK: - Styling

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }
}

// MARK: - Create group sheet

private struct CreateGroupSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var displayName = ""
    @State private var working = false
    @State private var created: GroupRef?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    ShareInviteSection(group: created, headline: "Group created")
                } else {
                    formSection
                }
            }
            .tint(Color.dromeClay)
            .scrollContentBackground(.hidden)
            .background(Color.dromeSand)
            .navigationTitle(created == nil ? "New group" : "Share the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .groupErrorAlert()
        }
    }

    private var formSection: some View {
        Group {
            Section {
                TextField("Group name", text: $name)
                    .frame(minHeight: DromeSpacing.tapTarget)
            } header: {
                header("Group name")
            } footer: {
                Text("What you'll all call this group.")
            }
            .listRowBackground(rowBackground)

            Section {
                TextField("Your display name", text: $displayName)
                    .frame(minHeight: DromeSpacing.tapTarget)
            } header: {
                header("Your display name")
            } footer: {
                Text("How you'll appear to this group. The group sees your display name, your day and current run, today's checkboxes, and whether this week's extra is done — nothing else.")
            }
            .listRowBackground(rowBackground)

            Section {
                Button {
                    submit()
                } label: {
                    HStack {
                        Spacer()
                        Text(working ? "Creating…" : "Create group")
                            .font(.headline.weight(.black))
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
                .foregroundStyle(canSubmit ? Color.dromeClay : Color.dromeInk.opacity(0.3))
                .frame(minHeight: DromeSpacing.tapTarget)
            }
            .listRowBackground(rowBackground)
        }
    }

    private func submit() {
        working = true
        Task {
            let ref = await appModel.createGroup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            working = false
            if let ref { created = ref } // else groupError alert shows
        }
    }

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }
}

// MARK: - Join group sheet

private struct JoinGroupSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var displayName = ""
    @State private var working = false

    private var canSubmit: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: DromeSpacing.tapTarget)
                } header: {
                    header("Invite code")
                } footer: {
                    Text("The 8-character code a friend shared with you.")
                }
                .listRowBackground(rowBackground)

                Section {
                    TextField("Your display name", text: $displayName)
                        .frame(minHeight: DromeSpacing.tapTarget)
                } header: {
                    header("Your display name")
                } footer: {
                    Text("How you'll appear to this group. The group sees your display name, your day and current run, today's checkboxes, and whether this week's extra is done — nothing else.")
                }
                .listRowBackground(rowBackground)

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            Text(working ? "Joining…" : "Join group")
                                .font(.headline.weight(.black))
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    .foregroundStyle(canSubmit ? Color.dromeClay : Color.dromeInk.opacity(0.3))
                    .frame(minHeight: DromeSpacing.tapTarget)
                }
                .listRowBackground(rowBackground)
            }
            .tint(Color.dromeClay)
            .scrollContentBackground(.hidden)
            .background(Color.dromeSand)
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .groupErrorAlert()
        }
    }

    private func submit() {
        working = true
        Task {
            let ref = await appModel.joinGroup(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            working = false
            if ref != nil { dismiss() } // else groupError alert shows
        }
    }

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }
}

// MARK: - Shared invite-code section (create success + detail header)

/// The invite code, big and monospaced, with copy + share affordances. Used on
/// the create-success panel and in GroupDetailView's header.
struct ShareInviteSection: View {
    let group: GroupRef
    var headline: String?

    @State private var copied = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                if let headline {
                    Text(headline)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.dromeDone)
                }
                HStack(spacing: DromeSpacing.m) {
                    Text(group.inviteCode)
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.dromeInk)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = group.inviteCode
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.dromeClay)
                            .frame(width: DromeSpacing.tapTarget, height: DromeSpacing.tapTarget)
                    }
                    .accessibilityLabel(copied ? "Code copied" : "Copy invite code")
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.dromeClay)
                            .frame(width: DromeSpacing.tapTarget, height: DromeSpacing.tapTarget)
                    }
                    .accessibilityLabel("Share invite code")
                }
            }
            .padding(.vertical, DromeSpacing.xs)
        } header: {
            Text("INVITE CODE")
                .font(.system(size: 13, weight: .black))
                .tracking(1.1)
                .foregroundStyle(Color.dromeInk.opacity(0.55))
        } footer: {
            Text("Share this code so friends can join \(group.name). It doesn't expire.")
        }
        .listRowBackground(Color.dromeInk.opacity(0.06))
    }

    private var shareText: String {
        "Join my Drome group \"\(group.name)\" with code \(group.inviteCode)."
    }
}

// MARK: - Shared group-error alert

private struct GroupErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        content.alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appModel.groupError != nil },
                set: { if !$0 { appModel.clearGroupError() } }
            )
        ) {
            Button("OK", role: .cancel) { appModel.clearGroupError() }
        } message: {
            Text(appModel.groupError ?? "")
        }
    }
}

extension View {
    func groupErrorAlert() -> some View { modifier(GroupErrorAlert()) }
}

// MARK: - Previews

#Preview("Signed out") {
    NavigationStack { GroupsView() }
        .environment(AppModel())
}
