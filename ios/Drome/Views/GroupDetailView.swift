//
//  GroupDetailView.swift
//  Drome
//
//  One group's members (docs/PHASE2.md "Groups"). Each member tile renders
//  ONLY what the server DTO carries — display name, the day they're on, their
//  current run, today's seven core-task dots, and a single weekly-extra dot
//  (labelled generically; the extra's name/id is never on the wire, so it
//  cannot leak). No photos, notes, diet text, or water amounts exist to show.
//
//  This is accountability, not competition: a one-tap "Nudge" is a wave hello,
//  never a shaming poke, and there is no ranking anywhere on this screen.
//

import SwiftUI
import UIKit

@MainActor
struct GroupDetailView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let groupId: String

    @State private var loadFailed = false
    @State private var leaveConfirm = false
    /// Opaque per-group handles I've nudged this session — the button flips to a
    /// quiet "Nudged" so a tap always gives honest feedback (and can't be
    /// spammed locally). Keyed by handle, never a global account id.
    @State private var nudged: Set<String> = []

    private var detail: GroupDetail? { appModel.groupDetails[groupId] }

    var body: some View {
        Form {
            if let detail {
                ShareInviteSection(group: GroupRef(
                    id: detail.id, name: detail.name, inviteCode: detail.inviteCode
                ))
                membersSection(detail)
                leaveSection(detail)
            } else if loadFailed {
                retrySection
            } else {
                loadingSection
            }
        }
        .tint(Color.dromeClay)
        .scrollContentBackground(.hidden)
        .background(Color.dromeSand)
        .navigationTitle(detail?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .groupErrorAlert()
        .confirmationDialog(
            "Leave \(detail?.name ?? "this group")?",
            isPresented: $leaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave group", role: .destructive) {
                Task { if await appModel.leaveGroup(id: groupId) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop seeing each other's progress. You can re-join anytime with the invite code.")
        }
    }

    private func load() async {
        loadFailed = !(await appModel.loadGroupDetail(id: groupId))
    }

    // MARK: - Members

    private func membersSection(_ detail: GroupDetail) -> some View {
        Section {
            ForEach(detail.members) { member in
                memberTile(member)
                    .padding(.vertical, DromeSpacing.xs)
            }
        } header: {
            sectionHeader(detail.members.count == 1 ? "1 member" : "\(detail.members.count) members")
        }
        .listRowBackground(rowBackground)
    }

    @ViewBuilder
    private func memberTile(_ member: GroupMember) -> some View {
        // "You" is flagged by the server (is_self), so the tile never needs — or
        // sees — a global account id.
        let isYou = member.isSelf
        VStack(alignment: .leading, spacing: DromeSpacing.s) {
            HStack(spacing: DromeSpacing.s) {
                Text(member.displayName.isEmpty ? "Member" : member.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.dromeInk)
                if isYou {
                    Text("you")
                        .font(.system(size: 11, weight: .black))
                        .tracking(0.5)
                        .foregroundStyle(Color.dromeSand)
                        .padding(.horizontal, DromeSpacing.s)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.dromeCamel))
                }
                Spacer(minLength: 0)
                if !isYou {
                    nudgeButton(member)
                }
            }

            if member.isActive, let tasks = member.tasks {
                let day = member.dayIndex ?? 0
                HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.s) {
                    // The server sends a RAW 1-based day index that can fall
                    // outside the challenge window (0/negative before it starts).
                    // Clamp the display so the tile never shows "DAY 0"; a
                    // not-yet-started member reads "STARTING SOON".
                    Text(day >= 1 ? "DAY \(day)" : "STARTING SOON")
                        .font(.system(size: 15, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeInk)
                    if day >= 1 {
                        Text(runCaption(member.currentRun ?? 0))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk.opacity(0.6))
                    }
                }
                taskDots(tasks: tasks, weeklyDone: member.weeklyExtraDone ?? false)
            } else {
                Text("Hasn't started a challenge yet.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
        }
    }

    private func runCaption(_ run: Int) -> String {
        run == 1 ? "1-day run" : "\(run)-day run"
    }

    /// The seven core-task dots followed by one generically-labelled weekly
    /// dot. Done = filled; not-done = hollow outline. Honest, never shaming.
    private func taskDots(tasks: GroupMemberTasks, weeklyDone: Bool) -> some View {
        HStack(spacing: DromeSpacing.s) {
            dot("Water", tasks.water)
            dot("Outdoor workout", tasks.outdoorWorkout)
            dot("Second workout", tasks.secondWorkout)
            dot("Reading", tasks.reading)
            dot("Diet", tasks.diet)
            dot("No junk or alcohol", tasks.noJunk)
            dot("Progress photo", tasks.photo)

            Rectangle()
                .fill(Color.dromeInk.opacity(0.15))
                .frame(width: 1, height: 16)
                .padding(.horizontal, DromeSpacing.xs)

            // Weekly extra — labelled generically on purpose: a member must
            // never learn *which* extra another is doing (privacy invariant).
            Image(systemName: weeklyDone ? "star.fill" : "star")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(weeklyDone ? Color.dromeCamel : Color.dromeInk.opacity(0.3))
                .accessibilityLabel("Weekly extra: \(weeklyDone ? "done" : "not done")")
        }
    }

    private func dot(_ label: String, _ done: Bool) -> some View {
        Circle()
            .fill(done ? Color.dromeDone : Color.clear)
            .frame(width: 14, height: 14)
            .overlay(
                Circle().strokeBorder(
                    done ? Color.dromeDone : Color.dromeInk.opacity(0.3),
                    lineWidth: 1.5
                )
            )
            .accessibilityLabel("\(label): \(done ? "done" : "not done")")
    }

    private func nudgeButton(_ member: GroupMember) -> some View {
        let didNudge = nudged.contains(member.handle)
        return Button {
            Task {
                if await appModel.nudge(groupId: groupId, toMemberHandle: member.handle) {
                    nudged.insert(member.handle)
                }
            }
        } label: {
            Label(didNudge ? "Nudged" : "Nudge", systemImage: didNudge ? "checkmark" : "hand.wave")
                .font(.footnote.weight(.bold))
                .foregroundStyle(didNudge ? Color.dromeInk.opacity(0.5) : Color.dromeClay)
                .padding(.horizontal, DromeSpacing.m)
                .frame(minHeight: DromeSpacing.tapTarget)
                .background(
                    Capsule().strokeBorder(
                        didNudge ? Color.dromeInk.opacity(0.25) : Color.dromeClay,
                        lineWidth: 1.5
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(didNudge)
        .accessibilityLabel(didNudge ? "Nudged \(member.displayName)" : "Nudge \(member.displayName)")
    }

    // MARK: - Leave / states

    private func leaveSection(_ detail: GroupDetail) -> some View {
        Section {
            Button("Leave group", role: .destructive) {
                leaveConfirm = true
            }
            .foregroundStyle(Color.dromeMiss)
            .frame(minHeight: DromeSpacing.tapTarget)
        } footer: {
            Text("Leaving stops you sharing progress with this group. Your challenge and history on this phone are untouched.")
        }
        .listRowBackground(rowBackground)
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: DromeSpacing.s) {
                ProgressView()
                Text("Loading group…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        }
        .listRowBackground(rowBackground)
    }

    private var retrySection: some View {
        Section {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                Text("Couldn't load this group")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.dromeInk)
                Text("Check your connection and try again.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                Button("Try again") {
                    Task { await load() }
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.dromeClay)
                .padding(.top, DromeSpacing.xs)
            }
            .padding(.vertical, DromeSpacing.xs)
        }
        .listRowBackground(rowBackground)
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
