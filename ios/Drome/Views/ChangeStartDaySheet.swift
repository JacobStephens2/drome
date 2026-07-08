//
//  ChangeStartDaySheet.swift
//  Drome
//
//  Post-onboarding "edit your Day 1" — corrects the challenge start date when
//  someone picked the wrong "already underway" day (or realizes it later).
//  Reuses the onboarding "I'm on Day N of 75" paradigm. In the core this is a
//  config-only edit (`set_start_date`): it renumbers days; logged entries keep
//  the calendar dates they were made on. Moving the start earlier opens up the
//  newly-uncovered days, which start empty and can be caught up from the board.
//

import SwiftUI

struct ChangeStartDaySheet: View {

    let client: DromeCoreClient
    let currentDayIndex: Int
    let lengthDays: Int
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dayNumber: Int
    @State private var errorMessage: String?

    init(client: DromeCoreClient, currentDayIndex: Int, lengthDays: Int, onChanged: @escaping () -> Void) {
        self.client = client
        self.currentDayIndex = currentDayIndex
        self.lengthDays = lengthDays
        self.onChanged = onChanged
        _dayNumber = State(initialValue: max(currentDayIndex, 1))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("I'm on Day")
                        Spacer()
                        TextField("\(max(currentDayIndex, 1))", value: $dayNumber, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .monospacedDigit()
                            .frame(width: 56)
                        Text("of \(lengthDays)")
                            .foregroundStyle(Color.dromeInk.opacity(0.6))
                    }
                    .frame(minHeight: DromeSpacing.tapTarget)
                    if clampedDay != currentDayIndex {
                        Text("Puts Day 1 on \(newStartDate.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.footnote)
                            .foregroundStyle(Color.dromeInk.opacity(0.7))
                    }
                } header: {
                    Text("What day are you on?")
                } footer: {
                    Text("Renumbers your days from the new start. Earlier starts open empty days you can catch up from your board.")
                }
            }
            .navigationTitle("Change start day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.bold)
                        .disabled(clampedDay == currentDayIndex)
                }
            }
            .alert(
                "Couldn't change the start day",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Entered day, clamped to the valid 1...lengthDays window.
    private var clampedDay: Int { min(max(dayNumber, 1), lengthDays) }

    /// Day 1's calendar date if today is `clampedDay`: today − (clampedDay − 1).
    private var newStartDate: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -(clampedDay - 1), to: cal.startOfDay(for: Date())) ?? Date()
    }

    private func save() {
        errorMessage = nil
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            try client.setStartDate(formatter.string(from: newStartDate))
            onChanged()
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

#Preview("Change start day") {
    ChangeStartDaySheet(client: MockDromeCore(), currentDayIndex: 5, lengthDays: 75, onChanged: {})
}
