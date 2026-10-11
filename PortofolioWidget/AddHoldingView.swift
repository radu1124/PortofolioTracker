//
//  AddHoldingView.swift
//  PortofolioWidget
//

import SwiftUI

enum FormMode: String, CaseIterable, Identifiable {
    case addPurchase = "Add Purchase"
    case edit = "Edit"
    var id: String { rawValue }
}

struct AddHoldingView: View {
    @Environment(\.dismiss) private var dismiss

    let store: PortfolioStore
    var editing: Holding?
    /// When set (and `editing` is nil), the ticker field starts pre-filled
    /// with this value. Combined with `matchedHolding` detection, this lets
    /// the caller jump straight into the mode picker for a known ticker.
    var prefillTicker: String?

    @State private var ticker: String = ""
    @State private var sharesText: String = ""
    @State private var priceText: String = ""
    @State private var currency: String = "EUR"
    @State private var date: Date = Date()
    /// Only meaningful when `matchedHolding != nil`. Defaults to `.addPurchase`
    /// for taps so the user lands on the top-up flow, but they can flip to
    /// `.edit` to see and modify the existing values (shares, avg price,
    /// currency, date).
    @State private var mode: FormMode = .addPurchase

    @State private var searchResults: [SymbolMatch] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var didPickFromSearch = false

    @State private var lookupQuote: Quote?
    @State private var lookupError: String?
    @State private var isLookingUp = false
    @State private var lookupTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                instrumentSection
                if let match = matchedHolding {
                    modePickerSection
                    if mode == .addPurchase {
                        existingPositionSection(match: match)
                    }
                }
                positionSection
                if mode == .addPurchase,
                   let match = matchedHolding,
                   let shares = parsed(sharesText),
                   let bp = parsed(priceText),
                   shares > 0, bp > 0 {
                    averagePreviewSection(match: match, addedShares: shares, addedPrice: bp)
                }
                if let q = lookupQuote, let shares = parsed(sharesText), let bp = parsed(priceText) {
                    previewSection(quote: q, shares: shares, buyPrice: bp)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: loadEditing)
            .onChange(of: existingMatch) { _, match in
                // When the user starts typing a ticker that matches an
                // existing holding, force the currency to match so the new
                // buy can be merged cleanly into a single weighted-average
                // position.
                if let match { currency = match.buyCurrency }
            }
            .onChange(of: mode) { _, newMode in
                // Swap the form contents to match the chosen mode. Edit loads
                // the existing values for inline modification; Add Purchase
                // clears them so the user enters the *new* buy.
                guard let match = matchedHolding else { return }
                switch newMode {
                case .edit:
                    sharesText = trimTrailingZeros(match.shares)
                    priceText = trimTrailingZeros(match.buyPrice)
                    currency = match.buyCurrency
                    date = match.buyDate
                case .addPurchase:
                    sharesText = ""
                    priceText = ""
                    date = Date()
                    currency = match.buyCurrency
                }
            }
            .onDisappear {
                searchTask?.cancel()
                lookupTask?.cancel()
            }
        }
        .preferredColorScheme(store.appearance.colorScheme)
    }

    /// The holding the user is implicitly working with — either an explicit
    /// edit target or one detected by typing its ticker.
    private var matchedHolding: Holding? {
        if let e = editing { return e }
        return existingMatch
    }

    /// Ticker-typed match (only when not in explicit edit mode).
    private var existingMatch: Holding? {
        guard editing == nil else { return nil }
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return nil }
        return store.holdings.first { $0.ticker.uppercased() == t }
    }

    private var navTitle: String {
        guard matchedHolding != nil else { return "Add Holding" }
        return mode == .addPurchase ? "Add Purchase" : "Edit Position"
    }

    private var confirmButtonLabel: String {
        guard matchedHolding != nil else { return "Add" }
        return mode == .addPurchase ? "Merge" : "Save"
    }

    private var sectionTitle: String {
        if matchedHolding == nil { return "Position" }
        return mode == .addPurchase ? "New Purchase" : "Position"
    }

    private var sharesFieldLabel: String {
        if matchedHolding == nil { return "Shares" }
        return mode == .addPurchase ? "Shares bought" : "Shares"
    }

    // MARK: - Sections

    private var instrumentSection: some View {
        Section("Instrument") {
            TextField("Ticker (e.g. AAPL, GOOG)", text: $ticker)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: ticker) { _, _ in
                    didPickFromSearch = false
                    scheduleSearch()
                    scheduleLookup()
                }

            if !searchResults.isEmpty && !didPickFromSearch {
                ForEach(searchResults.prefix(8)) { match in
                    Button(action: { pick(match) }) {
                        searchResultRow(match)
                    }
                    .buttonStyle(.plain)
                }
            }

            if editing == nil && !store.recentTickers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(store.recentTickers, id: \.self) { t in
                            Button(t) {
                                ticker = t
                                didPickFromSearch = true
                                searchResults = []
                                scheduleLookup()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            lookupRow
        }
    }

    private var modePickerSection: some View {
        Section {
            Picker("", selection: $mode) {
                ForEach(FormMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var positionSection: some View {
        let isLockedCurrency = mode == .addPurchase && matchedHolding != nil
        return Section(sectionTitle) {
            TextField(sharesFieldLabel, text: $sharesText)
                .keyboardType(.decimalPad)

            HStack {
                TextField("Buy price per share", text: $priceText)
                    .keyboardType(.decimalPad)
                if !isLockedCurrency {
                    Picker("", selection: $currency) {
                        ForEach(SupportedCurrency.all, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 70)
                } else {
                    // Currency is locked to the existing position so the
                    // weighted average is well-defined. Show it as a static
                    // label so the user knows what they're entering.
                    Text(currency)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }

            DatePicker("Buy date",
                       selection: $date,
                       in: ...Date(),
                       displayedComponents: .date)
        }
    }

    private func existingPositionSection(match: Holding) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding to \(match.ticker)")
                        .font(.caption.weight(.semibold))
                    Text("\(formatShares(match.shares)) @ \(format(match.buyPrice, currency: match.buyCurrency)) avg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func averagePreviewSection(match: Holding, addedShares: Double, addedPrice: Double) -> some View {
        let totalShares = match.shares + addedShares
        let totalCost = match.shares * match.buyPrice + addedShares * addedPrice
        let newAvg = totalShares > 0 ? totalCost / totalShares : 0
        return Section("After this purchase") {
            LabeledContent("Total shares") {
                Text(formatShares(totalShares))
            }
            LabeledContent("New average price") {
                Text(format(newAvg, currency: match.buyCurrency))
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private func formatShares(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...4)))
    }

    private func previewSection(quote q: Quote, shares: Double, buyPrice: Double) -> some View {
        Section("Preview") {
            let valueInQuoteCcy = shares * q.price
            let costInBuyCcy = shares * buyPrice
            let priceDelta = (q.price - buyPrice * convert(from: currency, to: q.currency)) * shares

            LabeledContent("Value") {
                Text(format(valueInQuoteCcy, currency: q.currency))
            }
            LabeledContent("Cost") {
                Text(format(costInBuyCcy, currency: currency))
            }
            if !q.currency.isEmpty && q.currency.uppercased() != currency.uppercased() {
                Label("Quote currency is \(q.currency), you paid in \(currency). FX impact will be shown on the main screen.",
                      systemImage: "arrow.left.arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                LabeledContent("Price P&L") {
                    Text("\(signed(priceDelta, currency: q.currency)) (\(signedPercent(buyPrice == 0 ? 0 : (q.price - buyPrice) / buyPrice)))")
                        .foregroundStyle(priceDelta >= 0 ? .green : .red)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(confirmButtonLabel, action: save)
                .disabled(!isValid)
        }
        if editing != nil {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", role: .destructive) {
                    if let e = editing {
                        store.remove(id: e.id)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private func searchResultRow(_ match: SymbolMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(match.symbol).bold()
                Spacer()
                if !match.exchange.isEmpty {
                    Text(match.exchange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if !match.name.isEmpty {
                    Text(match.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !match.type.isEmpty {
                    Text(match.type)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var lookupRow: some View {
        if isLookingUp {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        } else if let q = lookupQuote {
            HStack {
                Text("Current price").foregroundStyle(.secondary)
                Spacer()
                Text(format(q.price, currency: q.currency))
                Button {
                    priceText = String(format: "%.2f", q.price)
                    if !q.currency.isEmpty, SupportedCurrency.all.contains(q.currency) {
                        currency = q.currency
                    }
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .buttonStyle(.borderless)
                .help("Use as buy price")
            }
            .font(.footnote)
        } else if let err = lookupError, !searchResults.isEmpty == false {
            Text(err)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func pick(_ match: SymbolMatch) {
        ticker = match.symbol
        didPickFromSearch = true
        searchResults = []
        scheduleLookup()
    }

    private func loadEditing() {
        if let e = editing {
            // Tapped from the list. Seed the ticker + currency context but
            // leave shares/price/date blank — we default to Add Purchase mode
            // so those fields are for the *new* buy. If the user flips to
            // Edit, the onChange handler will populate them from the holding.
            ticker = e.ticker
            currency = e.buyCurrency
            mode = .addPurchase
            didPickFromSearch = true
            scheduleLookup()
        } else if let prefill = prefillTicker, ticker.isEmpty {
            ticker = prefill
            didPickFromSearch = true
            scheduleLookup()
        }
    }

    private func save() {
        let shares = parsed(sharesText) ?? 0
        let price = parsed(priceText) ?? 0
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()

        if let match = matchedHolding {
            if mode == .edit {
                // Direct replacement of the existing position values.
                var updated = match
                updated.ticker = t
                updated.shares = shares
                updated.buyPrice = price
                updated.buyCurrency = currency.uppercased()
                updated.buyDate = date
                store.update(updated)
            } else {
                // Merge into the existing position with a weighted-average
                // price. `buyDate` is preserved as the anchor — it's the
                // reference for the historical FX rate used in cost basis
                // and FX impact, and the user typically wants their oldest
                // entry date as the displayed buy date.
                var merged = match
                let totalShares = match.shares + shares
                guard totalShares > 0 else { dismiss(); return }
                let weightedPrice = (match.shares * match.buyPrice + shares * price) / totalShares
                merged.shares = totalShares
                merged.buyPrice = weightedPrice
                store.update(merged)
            }
        } else {
            store.add(Holding(
                ticker: t,
                shares: shares,
                buyPrice: price,
                buyCurrency: currency.uppercased(),
                buyDate: date
            ))
        }
        Task { await store.refresh() }
        dismiss()
    }

    // MARK: - Search & lookup scheduling

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = ticker.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let results = (try? await PriceService.shared.search(q)) ?? []
            if Task.isCancelled { return }
            searchResults = results
        }
    }

    private func scheduleLookup() {
        lookupTask?.cancel()
        let symbol = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        lookupQuote = nil
        lookupError = nil
        guard symbol.count >= 2 else {
            isLookingUp = false
            return
        }
        isLookingUp = true
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            do {
                let q = try await PriceService.shared.quote(for: symbol)
                if Task.isCancelled { return }
                lookupQuote = q
                lookupError = nil
                // If the user hasn't manually picked a currency yet, mirror the quote's.
                // Skip when adding to an existing position — currency must
                // stay locked to the existing one for the weighted average.
                if !q.currency.isEmpty,
                   SupportedCurrency.all.contains(q.currency),
                   editing == nil,
                   existingMatch == nil,
                   priceText.isEmpty {
                    currency = q.currency
                }
            } catch {
                if Task.isCancelled { return }
                lookupQuote = nil
                lookupError = "No exact match for \(symbol). Pick a suggestion above."
            }
            isLookingUp = false
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        let t = ticker.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        guard let s = parsed(sharesText), s > 0 else { return false }
        guard let p = parsed(priceText), p > 0 else { return false }
        return true
    }

    // MARK: - Helpers

    private func parsed(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func trimTrailingZeros(_ v: Double) -> String {
        let s = String(v)
        if s.hasSuffix(".0") { return String(s.dropLast(2)) }
        return s
    }

    private func format(_ v: Double, currency: String) -> String {
        let code = currency.isEmpty ? "EUR" : currency
        return v.formatted(.currency(code: code).precision(.fractionLength(2)))
    }

    private func signed(_ v: Double, currency: String) -> String {
        (v >= 0 ? "+" : "") + format(v, currency: currency)
    }

    private func signedPercent(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + v.formatted(.percent.precision(.fractionLength(2)))
    }

    /// Convert from one currency to another using the store's rate cache.
    private func convert(from: String, to: String) -> Double {
        store.currentRate(from: from, to: to)
    }
}
