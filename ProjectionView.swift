//
//  ProjectionView.swift
//  PortofolioWidget
//

import SwiftUI
import Charts

/// Per-holding projection assumptions. Stored per Holding.id so tweaks the
/// user makes on the existing portfolio survive across sessions.
struct HoldingProjectionParams: Codable, Equatable {
    var enabled: Bool = true
    var monthlyContribution: Double = 0
    var annualReturnPct: Double = 7.0
}

/// A hypothetical instrument the user is modelling but doesn't own yet —
/// lets them ask "what would this look like if I started buying X monthly?"
/// without touching the real holdings list.
struct ExtraInstrument: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var startingAmount: Double = 0
    var monthlyContribution: Double = 0
    var annualReturnPct: Double = 7.0
}

/// A single monthly step of the projection curve.
struct ProjectionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double           // projected total portfolio value
    let contributions: Double   // cumulative monthly contributions since t0
}

struct ProjectionView: View {
    @Environment(\.dismiss) private var dismiss
    let store: PortfolioStore

    @State private var years: Double = 10
    @State private var holdingParams: [UUID: HoldingProjectionParams] = [:]
    @State private var extras: [ExtraInstrument] = []

    private let settingsKey = "PortfolioWidget.ProjectionSettings.v1"

    private struct SavedSettings: Codable {
        var years: Double
        var holdingParams: [String: HoldingProjectionParams]
        var extras: [ExtraInstrument]
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                horizonSection
                summarySection
                chartSection
                holdingsSection
                extrasSection
                assumptionsSection
            }
            .navigationTitle("Projection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
            .onDisappear(perform: save)
        }
        .preferredColorScheme(store.appearance.colorScheme)
    }

    // MARK: - Sections

    private var horizonSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Horizon")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(horizonLabel)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Slider(value: $years, in: 1...40, step: 1)
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            let s = summary
            let growth = s.finalValue - s.starting - s.totalContributions
            LabeledContent("Starting value") {
                Text(format(s.starting))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Total contributions") {
                Text(format(s.totalContributions))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Growth") {
                Text(signed(growth))
                    .foregroundStyle(growth >= 0 ? .green : .red)
                    .font(.subheadline.weight(.semibold))
            }
            LabeledContent("Projected value") {
                Text(format(s.finalValue))
                    .font(.headline)
                    .contentTransition(.numericText())
            }
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        let points = series
        if points.count >= 2 {
            Section {
                Chart {
                    ForEach(points) { p in
                        AreaMark(
                            x: .value("Date", p.date),
                            yStart: .value("Bottom", yDomain(points).lowerBound),
                            yEnd: .value("Value", p.value),
                            series: .value("Series", "Projected")
                        )
                        .foregroundStyle(LinearGradient(
                            colors: [.blue.opacity(0.35), .blue.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Date", p.date),
                            y: .value("Value", p.value),
                            series: .value("Series", "Projected")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    }

                    let starting = points.first?.value ?? 0
                    ForEach(points) { p in
                        LineMark(
                            x: .value("Date", p.date),
                            y: .value("Value", starting + p.contributions),
                            series: .value("Series", "Contributed")
                        )
                        .foregroundStyle(.gray)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale([
                    "Projected": .blue,
                    "Contributed": .gray
                ])
                .chartYScale(domain: yDomain(points))
                .chartLegend(.visible)
                .frame(height: 220)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var holdingsSection: some View {
        if !store.holdings.isEmpty {
            Section("Current holdings") {
                ForEach(store.holdings) { h in
                    HoldingProjectionRow(
                        holding: h,
                        store: store,
                        params: bindingForHolding(h.id)
                    )
                }
            }
        }
    }

    private var extrasSection: some View {
        Section {
            ForEach($extras) { $extra in
                ExtraInstrumentRow(extra: $extra, currency: store.displayCurrency)
            }
            .onDelete { extras.remove(atOffsets: $0) }

            Button {
                extras.append(ExtraInstrument(
                    name: "",
                    startingAmount: 0,
                    monthlyContribution: 0,
                    annualReturnPct: 7.0
                ))
            } label: {
                Label("Add hypothetical instrument", systemImage: "plus.circle")
            }
        } header: {
            Text("What-if instruments")
        } footer: {
            Text("Model an instrument you don't own yet — set a starting amount (0 is fine), a monthly buy and an expected annual return.")
        }
    }

    private var assumptionsSection: some View {
        Section {
            Text("Growth is compounded monthly. Returns are nominal — inflation is not subtracted here. All amounts are in \(store.displayCurrency).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func bindingForHolding(_ id: UUID) -> Binding<HoldingProjectionParams> {
        Binding(
            get: { holdingParams[id] ?? HoldingProjectionParams() },
            set: { holdingParams[id] = $0 }
        )
    }

    // MARK: - Computation

    /// Builds the month-by-month projection curve. Each item (real holding
    /// or hypothetical) compounds independently at its own monthly rate,
    /// with a monthly contribution added at the end of each step.
    /// Formula per step: value = value * (1 + m_rate) + monthly_contribution.
    private var series: [ProjectionPoint] {
        let months = max(1, Int(years * 12))

        struct Item {
            var value: Double
            var monthlyContrib: Double
            var monthlyRate: Double
        }

        var items: [Item] = []
        for h in store.holdings {
            let p = holdingParams[h.id] ?? HoldingProjectionParams()
            guard p.enabled else { continue }
            let start = store.currentValue(of: h)
            let mRate = pow(1 + p.annualReturnPct / 100, 1.0 / 12) - 1
            items.append(Item(
                value: start,
                monthlyContrib: p.monthlyContribution,
                monthlyRate: mRate
            ))
        }
        for e in extras {
            let mRate = pow(1 + e.annualReturnPct / 100, 1.0 / 12) - 1
            items.append(Item(
                value: e.startingAmount,
                monthlyContrib: e.monthlyContribution,
                monthlyRate: mRate
            ))
        }

        let calendar = Calendar.current
        let now = Date()

        let startTotal = items.reduce(0.0) { $0 + $1.value }
        var points: [ProjectionPoint] = [
            ProjectionPoint(date: now, value: startTotal, contributions: 0)
        ]

        let monthlyContribSum = items.reduce(0.0) { $0 + $1.monthlyContrib }
        var cumContrib: Double = 0
        for m in 1...months {
            var total: Double = 0
            for i in 0..<items.count {
                items[i].value = items[i].value * (1 + items[i].monthlyRate) + items[i].monthlyContrib
                total += items[i].value
            }
            cumContrib += monthlyContribSum
            let date = calendar.date(byAdding: .month, value: m, to: now) ?? now
            points.append(ProjectionPoint(date: date, value: total, contributions: cumContrib))
        }

        return points
    }

    private struct SummaryFigures {
        let starting: Double
        let totalContributions: Double
        let finalValue: Double
    }

    private var summary: SummaryFigures {
        let s = series
        let starting = s.first?.value ?? 0
        let finalValue = s.last?.value ?? starting
        let contribs = s.last?.contributions ?? 0
        return SummaryFigures(
            starting: starting,
            totalContributions: contribs,
            finalValue: finalValue
        )
    }

    /// Y-axis domain that includes both the projected line and the pure
    /// contributions line, plus a bit of padding so the top of the curve
    /// isn't flush with the frame.
    private func yDomain(_ points: [ProjectionPoint]) -> ClosedRange<Double> {
        let starting = points.first?.value ?? 0
        let projectedValues = points.map { $0.value }
        let contribValues = points.map { starting + $0.contributions }
        let all = projectedValues + contribValues
        guard let minV = all.min(), let maxV = all.max() else { return 0...1 }
        let span = max(maxV - minV, max(maxV * 0.01, 1))
        let pad = span * 0.08
        return (minV - pad)...(maxV + pad)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return
        }
        years = saved.years
        var restored: [UUID: HoldingProjectionParams] = [:]
        for (key, value) in saved.holdingParams {
            if let uuid = UUID(uuidString: key) {
                restored[uuid] = value
            }
        }
        holdingParams = restored
        extras = saved.extras
    }

    private func save() {
        var mapped: [String: HoldingProjectionParams] = [:]
        for (id, params) in holdingParams {
            mapped[id.uuidString] = params
        }
        let saved = SavedSettings(
            years: years,
            holdingParams: mapped,
            extras: extras
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: - Formatting

    private var horizonLabel: String {
        let y = Int(years)
        return "\(y) year\(y == 1 ? "" : "s")"
    }

    private func format(_ v: Double) -> String {
        v.formatted(.currency(code: store.displayCurrency).precision(.fractionLength(0)))
    }

    private func signed(_ v: Double) -> String {
        let f = format(v)
        return v >= 0 ? "+\(f)" : f
    }
}

// MARK: - Rows

private struct HoldingProjectionRow: View {
    let holding: Holding
    let store: PortfolioStore
    @Binding var params: HoldingProjectionParams

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $params.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.ticker)
                        .font(.headline)
                    Text("Now: \(currentValueLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if params.enabled {
                Divider()
                numericRow(
                    label: "Monthly buy",
                    suffix: store.displayCurrency,
                    value: $params.monthlyContribution
                )
                numericRow(
                    label: "Expected return (annual)",
                    suffix: "%",
                    value: $params.annualReturnPct
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var currentValueLabel: String {
        let value = store.currentValue(of: holding)
        return value.formatted(.currency(code: store.displayCurrency).precision(.fractionLength(0)))
    }

    private func numericRow(label: String, suffix: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .leading)
        }
    }
}

private struct ExtraInstrumentRow: View {
    @Binding var extra: ExtraInstrument
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name (e.g. VUSA)", text: $extra.name)
                .font(.headline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            Divider()

            numericRow(
                label: "Starting amount",
                suffix: currency,
                value: $extra.startingAmount
            )
            numericRow(
                label: "Monthly buy",
                suffix: currency,
                value: $extra.monthlyContribution
            )
            numericRow(
                label: "Expected return (annual)",
                suffix: "%",
                value: $extra.annualReturnPct
            )
        }
        .padding(.vertical, 4)
    }

    private func numericRow(label: String, suffix: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .leading)
        }
    }
}

#Preview {
    ProjectionView(store: PortfolioStore())
}
