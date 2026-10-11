//
//  PortofolioStore.swift
//  PortofolioWidget
//

import Foundation
import Observation

@Observable
final class PortfolioStore {
    var holdings: [Holding] = []
    var quotes: [String: Quote] = [:]

    /// FX rate cache. Keys are either "BASE_TARGET" (latest) or
    /// "BASE_TARGET_YYYY-MM-DD" (historical). Value is target units per 1 unit
    /// of base, matching Frankfurter's response shape.
    var fxRates: [String: Double] = [:]

    var displayCurrency: String
    /// The currency the user thinks of as "real money" — the one in which FX
    /// gains/losses are felt. Independent of `displayCurrency`, which is just
    /// the unit used for showing totals. A Romanian investor would typically
    /// set this to RON regardless of whether they're glancing at the portfolio
    /// in EUR or USD on the summary card.
    var referenceCurrency: String
    var appearance: AppearanceMode
    var isRefreshing: Bool = false
    var lastError: String?
    var lastRefreshedAt: Date?

    var chartHistory: [PortfolioSnapshot] = []
    var isLoadingChart: Bool = false
    var chartRange: ChartRange = .threeMonths

    // MARK: - Inflation overlay
    //
    // When `inflationCountry` is non-nil, the chart card draws a second line
    // representing what cash of equivalent starting value would have needed
    // to grow to in order to merely keep up with CPI in that country.
    // The portfolio curve is re-expressed in that country's currency for
    // the comparison, so we're not mixing CPI-in-RON with value-in-EUR.

    var inflationCountry: InflationCountry?
    var inflationSeries: [InflationPoint] = []        // sampled to chartHistory dates
    var portfolioInCompareCurrency: [PortfolioSnapshot] = []
    var isLoadingInflation: Bool = false
    var inflationError: String?

    /// The canonical year-over-year inflation rate derived directly from the
    /// most recent CPI observations — i.e. what news outlets and official
    /// statistics agencies publish as "current inflation". For monthly
    /// (Eurostat) data this is `last_month / same_month_one_year_ago - 1`.
    /// For annual (World Bank) data this is `last_year / previous_year - 1`.
    var headlineInflationRate: Double?

    /// Latest 10Y government bond yields, keyed by FRED series ID
    /// (`BondCountry.seriesID`). Populated by `loadBondYields()` during
    /// `refresh()`.
    var bondYields: [String: BondYield] = [:]
    var isLoadingBondYields: Bool = false

    private let holdingsKey = "PortfolioWidget.Holdings.v1"
    private let displayCurrencyKey = "PortfolioWidget.DisplayCurrency.v1"
    private let referenceCurrencyKey = "PortfolioWidget.ReferenceCurrency.v1"
    private let appearanceKey = "PortfolioWidget.Appearance.v1"
    private let inflationCountryKey = "PortfolioWidget.InflationCountry.v1"

    init() {
        let display = UserDefaults.standard.string(forKey: "PortfolioWidget.DisplayCurrency.v1") ?? "EUR"
        self.displayCurrency = display
        // Default reference to whatever display is on first launch — most
        // users won't bother setting it separately.
        self.referenceCurrency = UserDefaults.standard.string(forKey: "PortfolioWidget.ReferenceCurrency.v1") ?? display
        let rawAppearance = UserDefaults.standard.string(forKey: "PortfolioWidget.Appearance.v1") ?? AppearanceMode.system.rawValue
        self.appearance = AppearanceMode(rawValue: rawAppearance) ?? .system
        if let code = UserDefaults.standard.string(forKey: "PortfolioWidget.InflationCountry.v1") {
            self.inflationCountry = InflationCountry.all.first { $0.seriesID == code }
        }
        load()
    }

    // MARK: - Mutations

    func add(_ holding: Holding) {
        holdings.append(holding)
        save()
    }

    func update(_ holding: Holding) {
        guard let idx = holdings.firstIndex(where: { $0.id == holding.id }) else { return }
        holdings[idx] = holding
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where holdings.indices.contains(index) {
            holdings.remove(at: index)
        }
        save()
    }

    func remove(id: UUID) {
        holdings.removeAll { $0.id == id }
        save()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceKey)
    }

    func setDisplayCurrency(_ code: String) {
        let new = code.uppercased()
        guard new != displayCurrency else { return }
        displayCurrency = new
        UserDefaults.standard.set(displayCurrency, forKey: displayCurrencyKey)
        // FX cache was anchored on the previous display currency basis;
        // simplest correct thing is to clear and refetch.
        fxRates.removeAll()
        Task { await refresh() }
    }

    func setReferenceCurrency(_ code: String) {
        let new = code.uppercased()
        guard new != referenceCurrency else { return }
        referenceCurrency = new
        UserDefaults.standard.set(referenceCurrency, forKey: referenceCurrencyKey)
        // Reference only affects how FX gains are *displayed*; no new rates
        // are needed beyond what refresh() already fetches.
    }

    /// Tickers the user has previously added, most recent first, deduplicated.
    var recentTickers: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for h in holdings.reversed() {
            if !seen.contains(h.ticker) {
                seen.insert(h.ticker)
                result.append(h.ticker)
            }
        }
        return result
    }

    // MARK: - Refresh

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let symbols = Array(Set(holdings.map { $0.ticker })).filter { !$0.isEmpty }
        var freshQuotes: [String: Quote] = [:]
        if !symbols.isEmpty {
            freshQuotes = await PriceService.shared.quotes(for: symbols)
            for (k, v) in freshQuotes { quotes[k] = v }
        }

        // FX: fetch one "latest" sheet with base = displayCurrency. Frankfurter
        // returns all rates from that base; we derive any X→Y via two lookups.
        do {
            let latest = try await FXService.shared.latest(base: displayCurrency)
            for (target, rate) in latest.rates {
                fxRates["\(displayCurrency.uppercased())_\(target.uppercased())"] = rate
            }
        } catch {
            // Non-fatal: rate lookups fall back to 1.0 (i.e. assume same currency).
        }

        // Historical: one fetch per unique buy date for non-display-ccy positions.
        let neededDates = Set(holdings.compactMap { h -> String? in
            if h.buyCurrency.uppercased() == displayCurrency.uppercased() { return nil }
            return Self.isoDateString(h.buyDate)
        })

        await withTaskGroup(of: (String, [String: Double]?).self) { group in
            for ds in neededDates {
                group.addTask {
                    let result = try? await FXService.shared.historical(date: ds, base: self.displayCurrency)
                    return (ds, result?.rates)
                }
            }
            for await (ds, rates) in group {
                guard let rates else { continue }
                for (target, rate) in rates {
                    fxRates["\(displayCurrency.uppercased())_\(target.uppercased())_\(ds)"] = rate
                }
            }
        }

        lastRefreshedAt = Date()

        let missing = symbols.filter { freshQuotes[$0] == nil && quotes[$0] == nil }
        lastError = missing.isEmpty ? nil : "Couldn't fetch: \(missing.joined(separator: ", "))"

        await loadHistory()
        await loadBondYields()
    }

    // MARK: - Bond yields

    func loadBondYields() async {
        isLoadingBondYields = true
        defer { isLoadingBondYields = false }

        await withTaskGroup(of: (String, BondYield?).self) { group in
            for c in BondCountry.all {
                group.addTask {
                    let y = try? await BondYieldService.shared.latestYield(for: c)
                    return (c.seriesID, y)
                }
            }
            for await (id, y) in group {
                if let y { bondYields[id] = y }
            }
        }
    }

    // MARK: - Historical chart

    func setChartRange(_ range: ChartRange) {
        guard range != chartRange else { return }
        chartRange = range
        Task { await loadHistory() }
    }

    func loadHistory() async {
        let range = chartRange
        isLoadingChart = true
        defer { isLoadingChart = false }

        let symbols = Array(Set(holdings.map { $0.ticker })).filter { !$0.isEmpty }
        guard !symbols.isEmpty else {
            chartHistory = []
            return
        }

        var priceHistories: [String: [HistoricalPrice]] = [:]
        await withTaskGroup(of: (String, [HistoricalPrice]?).self) { group in
            for s in symbols {
                group.addTask {
                    let h = try? await ChartService.shared.history(symbol: s, range: range)
                    return (s, h)
                }
            }
            for await (sym, hist) in group {
                if let hist { priceHistories[sym] = hist }
            }
        }

        var allDates: Set<Date> = []
        for hist in priceHistories.values {
            for p in hist { allDates.insert(p.date) }
        }
        let sortedDates = allDates.sorted()
        guard !sortedDates.isEmpty else {
            chartHistory = []
            return
        }

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        // Trim the chart so it starts no earlier than the *earliest* buy date
        // across the portfolio. There's no honest way to render days before
        // you owned anything, and showing them produces the +300% spike
        // artifact when positions "pop in" on their buy date.
        let buyDays = holdings.map { utcCal.startOfDay(for: $0.buyDate) }
        let earliestBuyDay = buyDays.min() ?? sortedDates.first!
        let activeDates = sortedDates.filter { $0 >= earliestBuyDay }
        guard !activeDates.isEmpty else {
            chartHistory = []
            return
        }

        var totalsByDate: [Date: Double] = [:]

        for h in holdings {
            let hist = (priceHistories[h.ticker] ?? []).sorted { $0.date < $1.date }
            guard !hist.isEmpty else { continue }
            // FX uses today's rate as a simplification; a daily FX time-series
            // would be more accurate but adds many more network calls.
            let listingCcy = quote(for: h.ticker)?.currency ?? h.buyCurrency
            let fxToDisplay = currentRate(from: listingCcy, to: displayCurrency)
            let buyDay = utcCal.startOfDay(for: h.buyDate)

            // For positions bought *after* the chart window starts, treat
            // their pre-purchase contribution as the cash you would have
            // held in `buyCurrency`. That keeps the curve continuous and
            // avoids fake jumps when a position enters mid-range.
            let cashEquivalentInDisplay =
                totalCostInBuyCurrency(of: h) * currentRate(from: h.buyCurrency, to: displayCurrency)

            var histIdx = 0
            var lastClose: Double = 0
            for date in activeDates {
                while histIdx < hist.count && hist[histIdx].date <= date {
                    lastClose = hist[histIdx].close
                    histIdx += 1
                }
                if date < buyDay {
                    totalsByDate[date, default: 0] += cashEquivalentInDisplay
                } else if lastClose > 0 {
                    totalsByDate[date, default: 0] += h.shares * lastClose * fxToDisplay
                } else {
                    // After buy date but no close yet (rare): fall back to
                    // cash equivalent so the position doesn't disappear.
                    totalsByDate[date, default: 0] += cashEquivalentInDisplay
                }
            }
        }

        chartHistory = activeDates.compactMap { d in
            guard let v = totalsByDate[d] else { return nil }
            return PortfolioSnapshot(date: d, value: v)
        }

        // Keep the inflation overlay aligned with the new chart window.
        await rebuildInflationOverlay()
    }

    // MARK: - Inflation overlay

    func setInflationCountry(_ country: InflationCountry?) {
        inflationCountry = country
        if let code = country?.seriesID {
            UserDefaults.standard.set(code, forKey: inflationCountryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: inflationCountryKey)
        }
        Task { await rebuildInflationOverlay() }
    }

    /// Recomputes both the portfolio curve re-expressed in the comparison
    /// country's currency, and the CPI-derived "keep up with inflation" line.
    /// Both series share the same dates as `chartHistory` so SwiftUI Charts
    /// can plot them on a single axis.
    func rebuildInflationOverlay() async {
        guard let country = inflationCountry else {
            inflationSeries = []
            portfolioInCompareCurrency = []
            headlineInflationRate = nil
            inflationError = nil
            return
        }
        guard !chartHistory.isEmpty else {
            inflationSeries = []
            portfolioInCompareCurrency = []
            headlineInflationRate = nil
            return
        }

        isLoadingInflation = true
        defer { isLoadingInflation = false }

        // Step 1: re-express the portfolio in the comparison currency. We
        // start from chartHistory (which is already in displayCurrency) and
        // apply today's FX. Using today's FX for the whole series is a
        // simplification; a daily FX history would be more precise but
        // costs a lot more network. The shape of the curve is preserved.
        let fx = currentRate(from: displayCurrency, to: country.currency)
        let portfolioCompare = chartHistory.map {
            PortfolioSnapshot(date: $0.date, value: $0.value * fx)
        }
        portfolioInCompareCurrency = portfolioCompare

        // Step 2: fetch CPI series for the country.
        let obs: [CPIObservation]
        do {
            obs = try await InflationService.shared.cpiSeries(series: country.seriesID)
        } catch {
            inflationError = "Couldn't load inflation data for \(country.displayName): \(error.localizedDescription)"
            inflationSeries = []
            return
        }
        guard obs.count >= 2 else {
            inflationError = "Not enough inflation data for \(country.displayName)."
            inflationSeries = []
            return
        }
        inflationError = nil

        // Step 3: build a date → CPI(date) sampler via linear interpolation
        // between adjacent observations. `obs.year` is encoded as
        // YYYY*100 + MM (monthly), with annual data using MM = 07.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        func anchorDate(forEncodedYM ym: Int) -> Date {
            let year = ym / 100
            let month = max(1, min(12, ym % 100))
            return utcCal.date(from: DateComponents(year: year, month: month, day: 15))!
        }
        let anchored: [(date: Date, value: Double)] = obs.map {
            (anchorDate(forEncodedYM: $0.year), $0.value)
        }

        // Headline YoY: this is the number the user looks up online. Compute
        // it directly from the data so it stays canonical regardless of the
        // chart window length.
        headlineInflationRate = Self.computeHeadlineYoY(anchored: anchored)

        // Estimate a recent annualised inflation rate so we can extrapolate
        // forward when the chart window extends past the latest CPI
        // observation (Eurostat lags ~2 weeks, World Bank can lag 6–18mo).
        //
        // The trailing window has to match the data frequency: 13 monthly
        // observations = 12-month YoY (correct), but 13 *annual* observations
        // = 12-year average, which smears out recent inflation badly. Detect
        // the cadence from the most recent two anchors and pick accordingly.
        let trailingCount: Int = {
            guard anchored.count >= 2 else { return anchored.count }
            let lastGapDays = anchored[anchored.count - 1].date
                .timeIntervalSince(anchored[anchored.count - 2].date) / 86_400
            if lastGapDays < 60 {
                // Monthly data → trailing 12 months (13 anchors).
                return min(13, anchored.count)
            } else {
                // Annual data → trailing 2 years (3 anchors). Recent but
                // smoothed enough to avoid a single-year spike dominating.
                return min(3, anchored.count)
            }
        }()
        let trailingStart = anchored[anchored.count - trailingCount]
        let trailingEnd = anchored.last!
        let trailingYears = max(
            trailingEnd.date.timeIntervalSince(trailingStart.date) / (365.25 * 86_400),
            1.0 / 12.0
        )
        let trailingGrowth = trailingEnd.value / trailingStart.value
        let annualisedRate = pow(trailingGrowth, 1.0 / trailingYears)  // e.g. 1.034 = 3.4%/yr

        func cpi(at date: Date) -> Double {
            // Before earliest anchor: clamp.
            if date <= anchored.first!.date { return anchored.first!.value }
            // After latest anchor: extrapolate using the recent annualised
            // rate. This keeps the inflation line moving for chart windows
            // that include "today" even when CPI hasn't been published yet.
            if date >= anchored.last!.date {
                let yearsAhead = date.timeIntervalSince(anchored.last!.date) / (365.25 * 86_400)
                return anchored.last!.value * pow(annualisedRate, yearsAhead)
            }
            for i in 0..<(anchored.count - 1) {
                let a = anchored[i], b = anchored[i + 1]
                if date >= a.date && date <= b.date {
                    let span = b.date.timeIntervalSince(a.date)
                    guard span > 0 else { return a.value }
                    let t = date.timeIntervalSince(a.date) / span
                    return a.value + (b.value - a.value) * t
                }
            }
            return anchored.last!.value
        }

        // Step 4: anchor the inflation line to the portfolio's starting
        // value, so the two lines are directly comparable.
        //   inflated_value(t) = start_value × CPI(t) / CPI(t0)
        let startDate = portfolioCompare.first!.date
        let startValue = portfolioCompare.first!.value
        let cpiAtStart = cpi(at: startDate)
        guard cpiAtStart > 0 else {
            inflationSeries = []
            return
        }

        inflationSeries = portfolioCompare.map { snap in
            InflationPoint(date: snap.date,
                           value: startValue * cpi(at: snap.date) / cpiAtStart)
        }

        // Diagnostic: log the actual CPI growth across the visible chart
        // window, so we can verify it matches official numbers (e.g.
        // RO ~5–6% on a 1Y window, ~13% on a 2Y window).
        if let first = inflationSeries.first?.value,
           let last = inflationSeries.last?.value,
           first > 0 {
            let pct = (last / first - 1) * 100
            print("[Inflation] \(country.displayName) over chart window: \(String(format: "%+.2f%%", pct)) (annualised rate used for extrapolation ≈ \(String(format: "%+.2f%%", (annualisedRate - 1) * 100)))")
        }
    }

    /// Rich summary of "did you beat inflation, and by how much?" — all
    /// numbers expressed in the comparison country's currency, evaluated
    /// over the currently visible chart window.
    struct InflationBeatSummary {
        let portfolioReturnPct: Double  // your return over the window
        let inflationPct: Double        // CPI growth over the window
        let realReturnPct: Double       // approx. portfolio − inflation
        let delta: Double               // absolute $ ahead/behind CPI line
        let deltaPct: Double            // delta relative to the CPI target
        let currency: String
        let country: InflationCountry
        let windowDays: Int             // how many days the window spans
        let annualisedInflationPct: Double  // CPI growth normalised to 1y

        var beatingInflation: Bool { delta >= 0 }
    }

    var inflationBeatSummary: InflationBeatSummary? {
        guard let country = inflationCountry,
              let portfolioStart = portfolioInCompareCurrency.first?.value,
              let portfolioEnd = portfolioInCompareCurrency.last?.value,
              let inflatedStart = inflationSeries.first?.value,
              let inflatedEnd = inflationSeries.last?.value,
              let startDate = inflationSeries.first?.date,
              let endDate = inflationSeries.last?.date,
              portfolioStart > 0, inflatedStart > 0, inflatedEnd > 0
        else { return nil }

        let portfolioReturnPct = (portfolioEnd - portfolioStart) / portfolioStart
        let inflationPct = (inflatedEnd - inflatedStart) / inflatedStart
        let realReturnPct = (1 + portfolioReturnPct) / (1 + inflationPct) - 1
        let delta = portfolioEnd - inflatedEnd
        let deltaPct = delta / inflatedEnd

        let days = max(1, Int(endDate.timeIntervalSince(startDate) / 86_400))
        let years = max(Double(days) / 365.25, 1.0 / 365.25)
        // Prefer the canonical YoY straight from CPI data; fall back to
        // window-derived annualisation only when the series is too short.
        let annualised = headlineInflationRate ?? (pow(1 + inflationPct, 1 / years) - 1)

        return InflationBeatSummary(
            portfolioReturnPct: portfolioReturnPct,
            inflationPct: inflationPct,
            realReturnPct: realReturnPct,
            delta: delta,
            deltaPct: deltaPct,
            currency: country.currency,
            country: country,
            windowDays: days,
            annualisedInflationPct: annualised
        )
    }

    // MARK: - FX lookup

    func currentRate(from: String, to: String) -> Double {
        let f = from.uppercased(), t = to.uppercased()
        if f == t { return 1.0 }
        let display = displayCurrency.uppercased()
        // Rates are stored as display → X. Derive X → Y as (display→Y) / (display→X).
        let toRate = (t == display) ? 1.0 : fxRates["\(display)_\(t)"]
        let fromRate = (f == display) ? 1.0 : fxRates["\(display)_\(f)"]
        guard let toR = toRate, let fromR = fromRate, fromR != 0 else { return 1.0 }
        return toR / fromR
    }

    func historicalRate(from: String, to: String, on date: Date) -> Double {
        let f = from.uppercased(), t = to.uppercased()
        if f == t { return 1.0 }
        let display = displayCurrency.uppercased()
        let ds = Self.isoDateString(date)
        let toRate = (t == display) ? 1.0 : fxRates["\(display)_\(t)_\(ds)"]
        let fromRate = (f == display) ? 1.0 : fxRates["\(display)_\(f)_\(ds)"]
        guard let toR = toRate, let fromR = fromRate, fromR != 0 else {
            return currentRate(from: f, to: t)
        }
        return toR / fromR
    }

    // MARK: - Per-holding math
    //
    // Mental model:
    //   The user paid `shares × buyPrice` in `buyCurrency` (e.g. RON) on
    //   `buyDate`. What they actually acquired, though, is `shares` of an
    //   asset that lives in its *listing* currency (e.g. EUR for VUSA). So
    //   the position is effectively held in the listing currency from the
    //   moment of purchase onward. Returns come from two places:
    //     1) price moves of the asset in its listing currency
    //     2) FX moves between buyCurrency and the listing currency
    //   Display currency is purely a presentation lens applied at the end.

    func quote(for ticker: String) -> Quote? { quotes[ticker.uppercased()] }

    /// The currency the security is listed in (i.e. the live quote's
    /// currency). Falls back to `buyCurrency` if we don't have a quote yet.
    private func listingCurrency(of h: Holding) -> String {
        if let c = quote(for: h.ticker)?.currency, !c.isEmpty { return c }
        return h.buyCurrency
    }

    /// Per-share cost expressed in the listing currency. If you bought a
    /// EUR-listed ETF for 564.74 RON/share when EUR/RON was ~4.97, this is
    /// roughly 113.6 EUR/share — the price you "really" paid in EUR terms.
    func costPerShareInListingCurrency(of h: Holding) -> Double {
        let listing = listingCurrency(of: h)
        return h.buyPrice * historicalRate(from: h.buyCurrency, to: listing, on: h.buyDate)
    }

    /// Total amount paid, in `buyCurrency` (what actually left your bank).
    func totalCostInBuyCurrency(of h: Holding) -> Double {
        h.shares * h.buyPrice
    }

    /// Current market value in the listing currency (no FX conversion).
    func currentValueInListingCurrency(of h: Holding) -> Double {
        if let q = quote(for: h.ticker), q.price > 0 {
            return h.shares * q.price
        }
        // No quote yet: fall back to cost so totals don't collapse to zero.
        return h.shares * costPerShareInListingCurrency(of: h)
    }

    /// Current market value in display currency.
    func currentValue(of h: Holding) -> Double {
        let listing = listingCurrency(of: h)
        return currentValueInListingCurrency(of: h) * currentRate(from: listing, to: displayCurrency)
    }

    /// Cost basis in display currency.
    ///
    /// We anchor cost in the currency the user actually paid in
    /// (`buyCurrency`) and convert that to the display currency at *today's*
    /// FX. That way, switching the display currency is just a re-scale and
    /// never creates phantom losses; the FX component shows up in `fxPnL`.
    func costAtBuy(of h: Holding) -> Double {
        totalCostInBuyCurrency(of: h) * currentRate(from: h.buyCurrency, to: displayCurrency)
    }

    /// Total P&L in display currency.
    /// For a RON→RON position, this is just (value_now_RON − cost_RON)
    /// converted to display ccy. For a RON→EUR position, it includes both
    /// the EUR price move and the RON/EUR FX move.
    func totalPnL(of h: Holding) -> Double {
        currentValue(of: h) - costAtBuy(of: h)
    }

    /// FX-only component of P&L, expressed in `referenceCurrency`.
    ///
    /// An FX gain only exists when the position actually has FX exposure:
    /// the cost currency (`buyCurrency`) differs from the listing currency.
    /// A RON-paid RON-listed ETF has no moving FX leg — there is nothing
    /// converted at any point — so the gain is always 0, regardless of what
    /// reference currency the user happens to view things in. (Restating a
    /// RON position in EUR doesn't conjure an EUR/RON gain out of nothing.)
    ///
    /// When exposure does exist, the gain is computed in `buyCurrency` (the
    /// currency the user paid in — where the gain materialises) and then
    /// re-expressed in `referenceCurrency` for the UI.
    func fxPnLInReference(of h: Holding) -> Double {
        let listing = listingCurrency(of: h)
        if listing.uppercased() == h.buyCurrency.uppercased() { return 0 }

        let costPerShareListing = costPerShareInListingCurrency(of: h)
        let hypotheticalInBuyCcy = h.shares * costPerShareListing
            * currentRate(from: listing, to: h.buyCurrency)
        let gainInBuyCcy = hypotheticalInBuyCcy - totalCostInBuyCurrency(of: h)
        return gainInBuyCcy * currentRate(from: h.buyCurrency, to: referenceCurrency)
    }

    /// Today's value change in display currency.
    func dayChange(of h: Holding) -> Double {
        guard let q = quote(for: h.ticker) else { return 0 }
        return h.shares * q.dayChange * currentRate(from: q.currency, to: displayCurrency)
    }

    // MARK: - Aggregates

    var totalCost: Double { holdings.reduce(0) { $0 + costAtBuy(of: $1) } }
    var totalValue: Double { holdings.reduce(0) { $0 + currentValue(of: $1) } }
    var totalPnL: Double { totalValue - totalCost }
    /// Total FX gain across all holdings, expressed in `referenceCurrency`.
    /// All per-holding gains are already in reference, so summing is direct.
    var totalFXPnL: Double {
        holdings.reduce(0) { $0 + fxPnLInReference(of: $1) }
    }
    var totalPnLPercent: Double { totalCost == 0 ? 0 : totalPnL / totalCost }

    var totalDayChange: Double { holdings.reduce(0) { $0 + dayChange(of: $1) } }
    var totalDayChangePercent: Double {
        let prev = totalValue - totalDayChange
        return prev == 0 ? 0 : totalDayChange / prev
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(holdings) else { return }
        UserDefaults.standard.set(data, forKey: holdingsKey)
        Task { await loadHistory() }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: holdingsKey),
              let decoded = try? JSONDecoder().decode([Holding].self, from: data) else { return }
        holdings = decoded
    }

    // MARK: - Helpers

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func isoDateString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Canonical year-over-year inflation rate from CPI observations.
    /// Returns nil if the series is too short to compute a YoY ratio.
    static func computeHeadlineYoY(anchored: [(date: Date, value: Double)]) -> Double? {
        guard anchored.count >= 2 else { return nil }
        let lastGapDays = anchored[anchored.count - 1].date
            .timeIntervalSince(anchored[anchored.count - 2].date) / 86_400

        if lastGapDays < 60 {
            // Monthly cadence (Eurostat). Compare the latest observation to
            // the one ~12 months earlier — exactly the YoY headline number.
            guard anchored.count >= 13 else { return nil }
            let now = anchored.last!.value
            let yearAgo = anchored[anchored.count - 13].value
            guard yearAgo > 0 else { return nil }
            return now / yearAgo - 1
        } else {
            // Annual cadence (World Bank). Latest annual CPI change.
            let now = anchored.last!.value
            let prev = anchored[anchored.count - 2].value
            guard prev > 0 else { return nil }
            return now / prev - 1
        }
    }
}
