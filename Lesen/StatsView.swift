import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dailyGoalMinutes") private var goal = 20
    @State private var ringProgress = 0.0

    private var todayMinutes: Int { library.todaySeconds / 60 }
    private var target: Double { min(1, Double(library.todaySeconds) / Double(max(1, goal * 60))) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    ring
                    Stepper(value: $goal, in: 5...180, step: 5) {
                        LabeledContent("Tagesziel", value: "\(goal) Min.")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack(spacing: 12) {
                        tile(value: "\(library.streak)", unit: library.streak == 1 ? "Tag" : "Tage", title: "Serie", symbol: "flame.fill")
                        tile(value: format(library.totalSeconds), unit: "", title: "Gesamt", symbol: "clock.fill")
                        tile(value: "\(library.books.filter { $0.finished }.count)", unit: "", title: "Gelesen", symbol: "checkmark.seal.fill")
                    }

                    week
                }
                .padding(20)
            }
            .navigationTitle("Lesestatistik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear {
                withAnimation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.15)) {
                    ringProgress = target
                }
            }
            .onChange(of: goal) { _, _ in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    ringProgress = target
                }
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 16)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    AngularGradient(colors: [Color(red: 0.85, green: 0.55, blue: 0.25), Color(red: 0.72, green: 0.18, blue: 0.20)],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(todayMinutes)")
                    .font(.system(size: 52, weight: .semibold, design: .serif))
                    .contentTransition(.numericText())
                Text("von \(goal) Minuten heute")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if target >= 1 {
                    Label("Ziel erreicht", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                }
            }
        }
        .frame(width: 210, height: 210)
        .padding(.top, 8)
    }

    private func tile(value: String, unit: String, title: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var week: some View {
        let days = library.lastSevenDays
        let peak = max(goal * 60, days.map { $0.seconds }.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("LETZTE 7 TAGE")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(day.seconds >= goal * 60
                                  ? Color(red: 0.72, green: 0.18, blue: 0.20)
                                  : Color.primary.opacity(0.35))
                            .frame(height: barHeight(day.seconds, peak: peak))
                        Text(day.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 136, alignment: .bottom)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func barHeight(_ seconds: Int, peak: Int) -> CGFloat {
        let share = CGFloat(seconds) / CGFloat(max(1, peak))
        return max(4, 110 * share)
    }

    private func format(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) Min." }
        return "\(minutes / 60) Std. \(minutes % 60) Min."
    }
}
