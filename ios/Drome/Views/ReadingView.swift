//
//  ReadingView.swift
//  Drome
//
//  Reading tile detail: pages-read-today vs 10 with a big "+10 pages"
//  primary action plus a stepper for other amounts, a quiet "Undo last
//  entry" correction that peels today's newest entry while any is live
//  (DayState.revocable.reading), the current book (editable), and total
//  pages across the challenge. "One book at a time" is a gentle nudge here,
//  not enforcement (purist enforcement is later).
//

import SwiftUI

struct ReadingView: View {
    @Environment(AppModel.self) private var appModel

    /// The SAME client instance that backs the AppModel. Needed for
    /// `setCurrentBook` and the challenge-total projection, which AppModel
    /// does not expose. Integration must pass the shared instance.
    private let client: any DromeCoreClient

    @State private var customPages = 5
    @State private var isEditingBook = false
    @State private var bookDraft = ""
    @State private var totalPages = 0
    @FocusState private var bookFieldFocused: Bool

    init(client: any DromeCoreClient) {
        self.client = client
    }

    private var pagesToday: Int { appModel.todayState?.day.pagesRead ?? 0 }
    private var readingDone: Bool { appModel.todayState?.day.readingDone ?? false }
    private var bookTitle: String { appModel.challenge?.currentBook ?? "" }

    /// At least one live reading entry is attributed to today — "Undo last
    /// entry" peels the newest one (backfill flags read false).
    private var readingRevocable: Bool { appModel.todayState?.day.revocable.reading ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DromeSpacing.l) {
                Text("Reading")
                    .dromeTitle()

                todaySection
                actionSection

                Rectangle()
                    .fill(Color.dromeInk.opacity(0.1))
                    .frame(height: 1)

                bookSection
                totalSection
            }
            .padding(DromeSpacing.m)
        }
        .background(Color.dromeSand.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            appModel.refresh()
            recomputeTotal()
        }
        .onChange(of: pagesToday) {
            recomputeTotal()
        }
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.s) {
            readingSectionLabel("TODAY")

            HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.xs) {
                Text("\(pagesToday)")
                    .dromeCounter()
                Text("of 10 pages")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.65))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.dromeInk.opacity(0.1))
                    Capsule()
                        .fill(readingDone ? Color.dromeDone : Color.dromeClay)
                        .frame(width: geo.size.width * min(1.0, Double(pagesToday) / 10.0))
                }
            }
            .frame(height: 8)

            if readingDone {
                Label("Reading done for today", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dromeDone)
            } else {
                Text("\(max(0, 10 - pagesToday)) to go")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk.opacity(0.65))
            }
        }
    }

    // MARK: - Log actions

    private var actionSection: some View {
        VStack(spacing: DromeSpacing.m) {
            Button {
                appModel.logReading(pages: 10)
            } label: {
                Text("+10 pages")
            }
            .buttonStyle(ReadingPrimaryButtonStyle())

            HStack(spacing: DromeSpacing.s) {
                stepButton("minus") { customPages = max(1, customPages - 1) }

                Text("\(customPages)")
                    .font(.system(size: 22, weight: .black))
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk)
                    .frame(minWidth: 52)

                stepButton("plus") { customPages = min(200, customPages + 1) }

                Spacer(minLength: DromeSpacing.s)

                Button {
                    appModel.logReading(pages: customPages)
                } label: {
                    Text("Log \(customPages)")
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeClay)
                        .padding(.horizontal, DromeSpacing.m)
                        .frame(minHeight: DromeSpacing.tapTarget)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.dromeClay, lineWidth: 2)
                        )
                }
            }

            // Quiet correction: peels today's newest entry (revokeTask
            // .reading), repeatable entry by entry until nothing live is
            // left. DayState doesn't expose per-entry page counts, so the
            // label stays generic; the total above updates on each peel.
            if readingRevocable {
                Button {
                    appModel.revokeTask(.reading)
                } label: {
                    Label("Undo last entry", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dromeInk.opacity(0.65))
                        .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo the last reading entry")
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(Color.dromeInk)
                .frame(width: DromeSpacing.tapTarget, height: DromeSpacing.tapTarget)
                .background(Circle().fill(Color.dromeInk.opacity(0.08)))
        }
    }

    // MARK: - Current book

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.s) {
            readingSectionLabel("CURRENT BOOK")

            if isEditingBook {
                HStack(spacing: DromeSpacing.s) {
                    TextField("Book title", text: $bookDraft)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.dromeInk)
                        .textFieldStyle(.plain)
                        .focused($bookFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(saveBook)
                        .padding(.horizontal, DromeSpacing.m)
                        .frame(minHeight: DromeSpacing.tapTarget)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.dromeInk.opacity(0.06))
                        )

                    Button(action: saveBook) {
                        Text("Save")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.dromeClay)
                    }
                    .dromeTapTarget()
                }
            } else {
                HStack(spacing: DromeSpacing.s) {
                    Text(bookTitle.isEmpty ? "No book set" : bookTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(bookTitle.isEmpty ? Color.dromeInk.opacity(0.5) : Color.dromeInk)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        bookDraft = bookTitle
                        isEditingBook = true
                        bookFieldFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.dromeClay)
                    }
                    .dromeTapTarget()
                    .accessibilityLabel("Edit book title")
                }
            }

            Text("One book at a time. Finish it, then change the title here.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.dromeInk.opacity(0.55))
        }
    }

    private func saveBook() {
        let title = bookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingBook = false
        bookFieldFocused = false
        guard !title.isEmpty, title != bookTitle else { return }
        do {
            try client.setCurrentBook(title)
            appModel.refresh()
        } catch {
            // Mock rarely throws; keep the old title on failure.
        }
    }

    // MARK: - Challenge total

    private var totalSection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            readingSectionLabel("THIS CHALLENGE")

            HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.xs) {
                Text("\(totalPages)")
                    .font(.system(size: 28, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(Color.dromeInk)
                Text("pages read total")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.65))
            }
        }
    }

    /// Sums `pagesRead` over the day projections from start through today.
    /// The pinned `ChallengeSummary` has no pages total, so this aggregates
    /// client-side; swap to the summary field if the core grows one.
    private func recomputeTotal() {
        guard let challenge = appModel.challenge,
              let todayDate = appModel.todayState?.date else {
            totalPages = 0
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        guard var cursor = formatter.date(from: challenge.startDate),
              let end = formatter.date(from: todayDate) else {
            totalPages = 0
            return
        }
        var total = 0
        var steps = 0
        while cursor <= end, steps < 400 {
            if let state = try? client.dayState(date: formatter.string(from: cursor)) {
                total += state.pagesRead
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            steps += 1
        }
        totalPages = total
    }

    private func readingSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(Color.dromeInk.opacity(0.5))
    }
}

// MARK: - Button style

private struct ReadingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .black))
            .tracking(-0.3)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeClay)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// MARK: - Previews

#Preview("Reading") {
    let core = MockDromeCore()
    return ReadingView(client: core)
        .environment(AppModel(core: core))
}

#Preview("Reading — done") {
    let core = MockDromeCore()
    _ = try? core.logReading(bookTitle: "Atomic Habits", pages: 12, effectiveDate: nil)
    return ReadingView(client: core)
        .environment(AppModel(core: core))
}
