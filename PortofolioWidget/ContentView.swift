//
//  ContentView.swift
//  PortofolioWidget
//

import SwiftUI
import Charts

struct ContentView: View {
    @State private var store = PortfolioStore()
    @State private var showingAdd = false
    @State private var showingProjection = false
    @State private var editing: Holding?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryCard(store: store)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if store.holdings.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No holdings yet",
                            systemImage: "chart.line.uptrend.xyaxis",
                            description: Text("Tap + to add a position. Try AAPL or GOOG.")
                        )
                    }
                } else {
                    Section {
                        ChartCard(store: store)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    Section("Holdings") {
                        ForEach(store.holdings) { h in
                            HoldingRow(holding: h, store: store)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = h }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }

                Section {
                    BondYieldsCard(store: store)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if let err = store.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Portfolio")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        if store.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isRefreshing)
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(SupportedCurrency.all, id: \.self) { code in
                            Button {
                                store.setDisplayCurrency(code)
                            } label: {
                                if code == store.displayCurrency {
                                    Label(code, systemImage: "checkmark")
                                } else {
                                    Text(code)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(store.displayCurrency)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Appearance", selection: Binding(
                            get: { store.appearance },
                            set: { store.setAppearance($0) }
                        )) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.icon).tag(mode)
                            }
                        }
                        Picker("Reference currency", selection: Binding(
                            get: { store.referenceCurrency },
                            set: { store.setReferenceCurrency($0) }
                        )) {
                            ForEach(SupportedCurrency.all, id: \.self) { code in
                                Text(code).tag(code)
                            }
                        }
                    } label: {
                        Image(systemName: store.appearance.icon)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingProjection = true } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis.circle")
                    }
                    .accessibilityLabel("Projection")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .preferredColorScheme(store.appearance.colorScheme)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showingAdd) {
                AddHoldingView(store: store)
            }
            .sheet(isPresented: $showingProjection) {
                ProjectionView(store: store)
            }
            .sheet(item: $editing) { h in
                AddHoldingView(store: store, editing: h)
            }
            .task { await store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.refresh() }
                }
            }
        }
    }
}

// MARK: - Summary card (widget-style)

private struct SummaryCard: View {
    let store: PortfolioStore
    @State private var showFXBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Total Value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let when = store.lastRefreshedAt {
                    Text(when, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(format(store.totalValue))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.default, value: store.totalValue)

            HStack(spacing: 12) {
                StatPill(
                    title: "Today",
                    amount: store.totalDayChange,
                    percent: store.totalDayChangePercent,
                    currencyCode: store.displayCurrency
                )
                StatPill(
                    title: "All-time",
                    amount: store.totalPnL,
                    percent: store.totalPnLPercent,
                    currencyCode: store.displayCurrency
                )
            }

            // Only surface FX results when the user is actually viewing the
            // portfolio in their base currency — that's the only lens where
            // "FX gain in RON" sits on the same axis as the rest of the
            // totals. In any other display, FX is a foreign-unit footnote
            // and adds confusion more than clarity.
            if abs(store.totalFXPnL) > 0.01,
               store.displayCurrency.uppercased() == store.referenceCurrency.uppercased() {
                Divider()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showFXBreakdown.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        BreakdownStat(
                            title: "FX gain",
                            amount: store.totalFXPnL,
                            currencyCode: store.referenceCurrency
                        )
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showFXBreakdown ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if showFXBreakdown {
                    FXBreakdownList(store: store)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background.secondary)
        )
    }

    private func format(_ v: Double) -> String {
        v.formatted(.currency(code: store.displayCurrency).precision(.fractionLength(2)))
    }
}

private struct StatPill: View {
    let title: String
    let amount: Double
    let percent: Double
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(signedAmount)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(signedPercent)
                .font(.caption2)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    private var color: Color { amount >= 0 ? .green : .red }

    private var signedAmount: String {
        let formatted = amount.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
        return amount >= 0 ? "+\(formatted)" : formatted
    }

    private var signedPercent: String {
        let formatted = percent.formatted(.percent.precision(.fractionLength(2)))
        return percent >= 0 ? "+\(formatted)" : formatted
    }
}

private struct FXBreakdownList: View {
    let store: PortfolioStore

    // All gains are in the same reference currency, so sorting by absolute
    // value is meaningful and aggregating in the summary line is honest.
    private var rows: [(holding: Holding, fxPnL: Double)] {
        store.holdings
            .map { ($0, store.fxPnLInReference(of: $0)) }
            .filter { abs($0.1) > 0.01 }
            .sorted { abs($0.1) > abs($1.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.holding.id) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.holding.ticker)
                            .font(.caption.weight(.semibold))
                        Text("paid in \(row.holding.buyCurrency)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(signed(row.fxPnL, code: store.referenceCurrency))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.fxPnL >= 0 ? .green : .red)
                }
            }

            if rows.isEmpty {
                Text("No FX impact per holding.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 6)
    }

    private func signed(_ v: Double, code: String) -> String {
        let f = v.formatted(.currency(code: code).precision(.fractionLength(2)))
        return v >= 0 ? "+\(f)" : f
    }
}

private struct BreakdownStat: View {
    let title: String
    let amount: Double
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(signedAmount)
                .font(.footnote.weight(.medium))
                .foregroundStyle(amount >= 0 ? .green : .red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signedAmount: String {
        let formatted = amount.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
        return amount >= 0 ? "+\(formatted)" : formatted
    }
}

// MARK: - Holding row

private struct HoldingRow: View {
    let holding: Holding
    let store: PortfolioStore

    var body: some View {
        let quote = store.quote(for: holding.ticker)
        let value = store.currentValue(of: holding)
        let pnl = store.totalPnL(of: holding)
        // FX gain anchored in the user's reference currency — independent of
        // whatever display currency they're viewing the portfolio in.
        let fxPnL = store.fxPnLInReference(of: holding)
        let cost = store.costAtBuy(of: holding)
        let pct = cost == 0 ? 0 : pnl / cost
        let dayChange = store.dayChange(of: holding)
        let dayPct = quote?.dayChangePercent ?? 0

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(holding.ticker)
                    .font(.headline)
                Text("\(formatShares(holding.shares)) @ \(formatMoney(holding.buyPrice, code: holding.buyCurrency))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(holding.buyDate, format: .dateTime.year().month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if quote != nil {
                    Text(formatMoney(value, code: store.displayCurrency))
                        .font(.headline)
                    HStack(spacing: 4) {
                        Image(systemName: dayChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text("\(signedMoney(dayChange, code: store.displayCurrency)) (\(signedPercent(dayPct)))")
                            .font(.caption)
                    }
                    .foregroundStyle(dayChange >= 0 ? .green : .red)
                    Text("All: \(signedMoney(pnl, code: store.displayCurrency)) (\(signedPercent(pct)))")
                        .font(.caption2)
                        .foregroundStyle(pnl >= 0 ? .green : .red)
                    if abs(fxPnL) > 0.01,
                       store.displayCurrency.uppercased() == store.referenceCurrency.uppercased() {
                        Text("FX \(signedMoney(fxPnL, code: store.referenceCurrency))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let q = quote {
                        Text(formatMoney(q.price, code: q.currency))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                    Text("loading…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatShares(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...4)))
    }

    private func formatMoney(_ v: Double, code: String) -> String {
        let safe = code.isEmpty ? "EUR" : code
        return v.formatted(.currency(code: safe).precision(.fractionLength(2)))
    }

    private func signedMoney(_ v: Double, code: String) -> String {
        let s = formatMoney(v, code: code)
        return v >= 0 ? "+\(s)" : s
    }

    private func signedPercent(_ v: Double) -> String {
        let s = v.formatted(.percent.precision(.fractionLength(2)))
        return v >= 0 ? "+\(s)" : s
    }
}

// MARK: - Chart card

private struct ChartCard: View {
    let store: PortfolioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let perf = rangePerformance {
                        HStack(spacing: 4) {
                            Text(signed(perf.delta, code: chartCurrency))
                                .font(.subheadline.weight(.semibold))
                            Text("(\(signedPercent(perf.pct)))")
                                .font(.caption)
                        }
                        .foregroundStyle(perf.delta >= 0 ? .green : .red)
                    }
                }
                Spacer()
                inflationPicker
                if store.isLoadingChart || store.isLoadingInflation {
                    ProgressView().controlSize(.small)
                }
            }

            chart

            if let summary = store.inflationBeatSummary {
                InflationBeatBanner(summary: summary)
            } else if store.inflationCountry != nil, let err = store.inflationError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Picker("Range", selection: Binding(
                get: { store.chartRange },
                set: { store.setChartRange($0) }
            )) {
                ForEach(ChartRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background.secondary)
        )
    }

    // The currency the chart is drawn in. When an inflation comparison is
    // active, we switch to the country's currency so the two lines are
    // directly comparable (you can't compare RON-CPI with EUR-portfolio
    // value and learn anything).
    private var chartCurrency: String {
        store.inflationCountry?.currency ?? store.displayCurrency
    }

    private var displayedPortfolioSeries: [PortfolioSnapshot] {
        store.inflationCountry == nil ? store.chartHistory : store.portfolioInCompareCurrency
    }

    @ViewBuilder
    private var inflationPicker: some View {
        Menu {
            Button {
                store.setInflationCountry(nil)
            } label: {
                if store.inflationCountry == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            Divider()
            ForEach(InflationCountry.all) { c in
                Button {
                    store.setInflationCountry(c)
                } label: {
                    let title = "\(c.flag) \(c.displayName)"
                    if store.inflationCountry?.id == c.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption)
                Text(store.inflationCountry?.flag ?? "vs CPI")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule().fill(.background.tertiary)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var chart: some View {
        let series = displayedPortfolioSeries
        if series.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background.tertiary)
                Text(store.isLoadingChart ? "Building chart…" : "Not enough data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 180)
        } else {
            let domain = yAxisDomain
            Chart {
                ForEach(series) { snap in
                    AreaMark(
                        x: .value("Date", snap.date),
                        yStart: .value("Bottom", domain.lowerBound),
                        yEnd: .value("Value", snap.value),
                        series: .value("Series", "Portfolio")
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [lineColor.opacity(0.35), lineColor.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", snap.date),
                        y: .value("Value", snap.value),
                        series: .value("Series", "Portfolio")
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }

                ForEach(store.inflationSeries) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Inflation", point.value),
                        series: .value("Series", "Inflation")
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale([
                "Portfolio": lineColor,
                "Inflation": .orange
            ])
            .chartLegend(store.inflationCountry == nil ? .hidden : .visible)
            .chartYScale(domain: yAxisDomain)
            .frame(height: 180)
        }
    }

    // MARK: - Derived

    private var rangePerformance: (delta: Double, pct: Double)? {
        let series = displayedPortfolioSeries
        guard let first = series.first?.value,
              first > 0,
              let last = series.last?.value else { return nil }
        let delta = last - first
        return (delta, delta / first)
    }

    private var lineColor: Color {
        guard let perf = rangePerformance else { return .blue }
        return perf.delta >= 0 ? .green : .red
    }

    private var yAxisDomain: ClosedRange<Double> {
        var values = displayedPortfolioSeries.map { $0.value }
        values.append(contentsOf: store.inflationSeries.map { $0.value })
        guard let minV = values.min(), let maxV = values.max() else {
            return 0...1
        }
        let span = max(maxV - minV, max(maxV * 0.01, 1))
        let pad = span * 0.1
        return (minV - pad)...(maxV + pad)
    }

    private func signed(_ v: Double, code: String) -> String {
        let f = v.formatted(.currency(code: code).precision(.fractionLength(2)))
        return v >= 0 ? "+\(f)" : f
    }

    private func signedPercent(_ v: Double) -> String {
        let f = v.formatted(.percent.precision(.fractionLength(2)))
        return v >= 0 ? "+\(f)" : f
    }
}

private struct InflationBeatBanner: View {
    let summary: PortfolioStore.InflationBeatSummary

    var body: some View {
        let accent: Color = summary.beatingInflation ? .green : .orange
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: summary.beatingInflation
                      ? "checkmark.seal.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption.weight(.semibold))
                    Text(subline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Side-by-side breakdown: your return, CPI, real return.
            HStack(spacing: 8) {
                metric(title: "Your return",
                       value: signedPercent(summary.portfolioReturnPct),
                       tint: summary.portfolioReturnPct >= 0 ? .green : .red)
                metric(title: "\(summary.country.flag) CPI",
                       value: signedPercent(summary.inflationPct),
                       tint: .orange)
                metric(title: "Real",
                       value: signedPercent(summary.realReturnPct),
                       tint: summary.realReturnPct >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.12))
        )
    }

    private var headline: String {
        summary.beatingInflation
            ? "Beating inflation in \(summary.country.displayName)"
            : "Behind inflation in \(summary.country.displayName)"
    }

    private var subline: String {
        let amount = signed(summary.delta)
        let relative = signedPercent(summary.deltaPct)
        return "\(amount) (\(relative)) vs. the CPI-matched value · \(windowLabel) · \(signedPercent(summary.annualisedInflationPct)) YoY"
    }

    private var windowLabel: String {
        let d = summary.windowDays
        if d < 45 { return "\(d)d window" }
        if d < 365 { return "\(d/30)mo window" }
        let years = Double(d) / 365.25
        return String(format: "%.1fy window", years)
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private func signed(_ v: Double) -> String {
        let f = v.formatted(.currency(code: summary.currency).precision(.fractionLength(2)))
        return v >= 0 ? "+\(f)" : f
    }

    private func signedPercent(_ v: Double) -> String {
        let f = v.formatted(.percent.precision(.fractionLength(2)))
        return v >= 0 ? "+\(f)" : f
    }
}

// MARK: - Bond yields card

private struct BondYieldsCard: View {
    let store: PortfolioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("10Y Government Bonds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoadingBondYields {
                    ProgressView().controlSize(.small)
                }
            }

            VStack(spacing: 10) {
                ForEach(BondCountry.all) { country in
                    BondYieldRow(country: country, store: store)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background.secondary)
        )
    }
}

private struct BondYieldRow: View {
    let country: BondCountry
    let store: PortfolioStore

    var body: some View {
        HStack(spacing: 12) {
            Text(country.flag)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(country.displayName)
                    .font(.callout.weight(.semibold))
                Text("\(country.tenor) · \(country.currency)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let yield = store.bondYields[country.seriesID] {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(yield.value.formatted(.number.precision(.fractionLength(2))) + "%")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Text(yield.date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

#Preview {
    ContentView()
}
