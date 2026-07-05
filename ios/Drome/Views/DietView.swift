//
//  DietView.swift
//  Drome
//
//  Diet tile detail: the diet the user named at setup and one big attest
//  button. Attested reads decisively done; un-attest works anytime a live
//  attest backs it (`DayState.revocable.diet` — not session-gated), as a
//  plain correction via `revokeTask`. A day attested only by a backfill
//  flag reads done with nothing to un-mark. Deliberately nothing else — no
//  food logging, no calories, by design.
//

import SwiftUI

struct DietView: View {
    @Environment(AppModel.self) private var appModel

    init() {}

    private var dietDone: Bool { appModel.todayState?.day.dietDone ?? false }

    /// A live attest event backs today's done — un-marking would succeed.
    private var dietRevocable: Bool { appModel.todayState?.day.revocable.diet ?? false }

    private var dietText: String {
        let text = (appModel.challenge?.dietDescription ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The diet you named at the start" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.l) {
            Text("Diet")
                .dromeTitle()

            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                Text("YOUR DIET")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.dromeInk.opacity(0.5))
                Text(dietText)
                    .font(.system(size: 24, weight: .black))
                    .tracking(-0.5)
                    .foregroundStyle(Color.dromeInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DromeSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeInk.opacity(0.06))
            )

            Spacer(minLength: DromeSpacing.m)

            if dietDone {
                doneBlock
            } else {
                Button {
                    appModel.logDietOk()
                } label: {
                    Text("Kept my diet today")
                }
                .buttonStyle(DietPrimaryButtonStyle())
            }

            Text("No food logging. No calories. By design.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dromeInk.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(DromeSpacing.m)
        .background(Color.dromeSand.ignoresSafeArea())
        .onAppear { appModel.refresh() }
    }

    private var doneBlock: some View {
        VStack(spacing: DromeSpacing.m) {
            HStack(spacing: DromeSpacing.s) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .black))
                Text("Diet kept.")
                    .font(.system(size: 24, weight: .black))
                    .tracking(-0.5)
            }
            .foregroundStyle(Color.dromeDone)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeDone.opacity(0.12))
            )

            // A quiet correction, available whenever a live attest backs
            // the done state — no session gate, no confirmation, no shame.
            if dietRevocable {
                Button {
                    appModel.revokeTask(.diet)
                } label: {
                    Text("Un-mark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.dromeInk.opacity(0.7))
                }
                .dromeTapTarget()
                .accessibilityLabel("Un-mark diet for today")
            }
        }
    }
}

// MARK: - Button style

private struct DietPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .black))
            .tracking(-0.3)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeClay)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// MARK: - Previews

#Preview("Diet — not attested") {
    let core = MockDromeCore()
    return DietView()
        .environment(AppModel(core: core))
}

#Preview("Diet — attested") {
    let core = MockDromeCore()
    _ = try? core.logDietOk(effectiveDate: nil)
    return DietView()
        .environment(AppModel(core: core))
}
