//
//  Models.swift
//  PortofolioWidget
//

import Foundation

struct Holding: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var ticker: String
    var shares: Double
    var buyPrice: Double
    var buyCurrency: String
    var buyDate: Date

    init(id: UUID = UUID(),
         ticker: String,
         shares: Double,
         buyPrice: Double,
         buyCurrency: String = "EUR",
         buyDate: Date = Date()) {
        self.id = id
        self.ticker = ticker.uppercased()
        self.shares = shares
        self.buyPrice = buyPrice
        self.buyCurrency = buyCurrency.uppercased()
        self.buyDate = buyDate
    }

    var cost: Double { shares * buyPrice }

    // Custom decoding so older saved records without `buyCurrency` still load.
    private enum CodingKeys: String, CodingKey {
        case id, ticker, shares, buyPrice, buyCurrency, buyDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ticker = try c.decode(String.self, forKey: .ticker)
        shares = try c.decode(Double.self, forKey: .shares)
        buyPrice = try c.decode(Double.self, forKey: .buyPrice)
        buyCurrency = (try c.decodeIfPresent(String.self, forKey: .buyCurrency)) ?? "EUR"
        buyDate = try c.decode(Date.self, forKey: .buyDate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ticker, forKey: .ticker)
        try c.encode(shares, forKey: .shares)
        try c.encode(buyPrice, forKey: .buyPrice)
        try c.encode(buyCurrency, forKey: .buyCurrency)
        try c.encode(buyDate, forKey: .buyDate)
    }
}

struct Quote: Equatable, Hashable {
    let symbol: String
    let price: Double
    let previousClose: Double
    let currency: String

    var dayChange: Double { price - previousClose }
    var dayChangePercent: Double {
        previousClose == 0 ? 0 : (price - previousClose) / previousClose
    }
}

struct SymbolMatch: Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let exchange: String
    let type: String
    let currency: String?
}

enum ChartRange: String, CaseIterable, Identifiable, Codable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case fiveYears = "5Y"
    case max = "MAX"

    var id: String { rawValue }

    var yahooRange: String {
        switch self {
        case .oneMonth: return "1mo"
        case .threeMonths: return "3mo"
        case .sixMonths: return "6mo"
        case .oneYear: return "1y"
        case .fiveYears: return "5y"
        case .max: return "max"
        }
    }

    var interval: String {
        switch self {
        case .oneMonth, .threeMonths, .sixMonths, .oneYear: return "1d"
        case .fiveYears, .max: return "1wk"
        }
    }
}

struct PortfolioSnapshot: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

/// A point on the inflation overlay line. `value` is the "what your starting
/// cash would have needed to become to keep pace with CPI" amount, expressed
/// in the comparison country's currency.
struct InflationPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.righthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// A short list of currencies the user can pick when entering a position.
/// These are all supported by Frankfurter (ECB rates).
enum SupportedCurrency {
    static let all: [String] = [
        "EUR", "USD", "GBP", "RON", "CHF", "JPY",
        "CAD", "AUD", "SEK", "NOK", "DKK", "PLN",
        "CZK", "HUF", "BGN", "TRY", "CNY", "HKD",
        "SGD", "NZD", "ZAR", "MXN", "BRL", "INR", "KRW"
    ]
}

/// A country whose CPI series we can plot against the portfolio. The
/// `seriesID` is the FRED series identifier the inflation service queries.
/// `currency` is the currency we'll express the portfolio in when
/// comparing, so the comparison stays apples-to-apples.
struct InflationCountry: Identifiable, Hashable, Codable {
    var id: String { seriesID }
    let seriesID: String        // e.g. "RONCPIALLMINMEI"
    let displayName: String     // e.g. "Romania"
    let currency: String        // e.g. "RON"
    let flag: String            // emoji, just for the picker

    // All FRED monthly CPI series.
    //   • Euro area: Eurostat HICP mirrored on FRED (active, fresh).
    //   • US: BLS CPIAUCSL — the canonical US CPI series, long history.
    static let all: [InflationCountry] = [
        .init(seriesID: "CP0000EZ19M086NEST", displayName: "Euro area",     currency: "EUR", flag: "🇪🇺"),
        .init(seriesID: "CPIAUCSL",           displayName: "United States", currency: "USD", flag: "🇺🇸")
    ]
}

/// One CPI observation. We use monthly FRED series (index scale varies by
/// series — 2015=100 for OECD, 1982–84=100 for CPIAUCSL — but we only ever
/// take ratios, so the base doesn't matter). `year` is encoded as
/// `year * 100 + month` so monthly anchors sort and interpolate uniformly.
struct CPIObservation: Hashable, Codable {
    let year: Int
    let value: Double
}

/// Source for a bond yield series. FRED covers US (`DGS10`, daily) reliably
/// and Euro area via OECD MEI. Romania isn't on FRED in any working series,
/// so we go direct to ECB's Statistical Data Warehouse (Maastricht 10Y).
enum BondSource: Hashable {
    case fred
    case ecb
}

/// A country whose 10-year government bond yield we display.
/// `seriesID` is either a FRED series ID or an ECB series key, depending on
/// `source`.
struct BondCountry: Identifiable, Hashable {
    var id: String { seriesID }
    let seriesID: String
    let source: BondSource
    let displayName: String
    let currency: String
    let flag: String
    let tenor: String      // e.g. "10Y" — purely a label

    static let all: [BondCountry] = [
        .init(seriesID: "DGS10",
              source: .fred,
              displayName: "United States", currency: "USD", flag: "🇺🇸", tenor: "10Y"),
        .init(seriesID: "IRLTLT01EZM156N",
              source: .fred,
              displayName: "Euro area",     currency: "EUR", flag: "🇪🇺", tenor: "10Y"),
        .init(seriesID: "M.RO.L.L40.CI.0000.RON.N.Z",
              source: .ecb,
              displayName: "Romania",       currency: "RON", flag: "🇷🇴", tenor: "10Y")
    ]
}

/// Latest yield observation for a single bond series.
struct BondYield: Hashable {
    let value: Double  // percent (e.g. 4.27 = 4.27%)
    let date: Date
}
