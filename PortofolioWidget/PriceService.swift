//
//  PriceService.swift
//  PortofolioWidget
//
//  Fetches live quotes and symbol-search results from Yahoo Finance's public
//  endpoints. No API key required.
//

import Foundation

actor PriceService {
    static let shared = PriceService()

    private var quoteCache: [String: (quote: Quote, fetchedAt: Date)] = [:]
    private var searchCache: [String: (results: [SymbolMatch], fetchedAt: Date)] = [:]
    private let cacheDuration: TimeInterval = 60

    // MARK: - Quote

    func quote(for symbol: String) async throws -> Quote {
        let key = symbol.uppercased()
        if let cached = quoteCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheDuration {
            return cached.quote
        }
        do {
            let quote = try await fetchYahooQuote(symbol: key)
            quoteCache[key] = (quote, Date())
            return quote
        } catch PriceError.notFound where !key.contains(".") {
            // Yahoo hides BVB-listed instruments behind a country suffix.
            // Try the Romanian ones before giving up so users don't have to
            // type the exact Yahoo symbol when entering a ticker.
            for suffix in Self.bvbSuffixes {
                do {
                    let q = try await fetchYahooQuote(symbol: key + suffix)
                    quoteCache[key] = (q, Date())
                    return q
                } catch PriceError.notFound {
                    continue
                }
            }
            throw PriceError.notFound
        }
    }

    fileprivate static let bvbSuffixes = [".RO", ".BVB"]

    func quotes(for symbols: [String]) async -> [String: Quote] {
        await withTaskGroup(of: (String, Quote?).self) { group in
            for symbol in symbols {
                group.addTask {
                    let q = try? await self.quote(for: symbol)
                    return (symbol.uppercased(), q)
                }
            }
            var result: [String: Quote] = [:]
            for await (sym, q) in group {
                if let q { result[sym] = q }
            }
            return result
        }
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [SymbolMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        let key = q.lowercased()
        if let cached = searchCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheDuration {
            return cached.results
        }
        let results = try await fetchYahooSearch(query: q)
        searchCache[key] = (results, Date())
        return results
    }

    // MARK: - Network

    private func fetchYahooQuote(symbol: String) async throws -> Quote {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)")!
        components.queryItems = [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "range", value: "5d")
        ]
        guard let url = components.url else { throw PriceError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PriceError.badResponse
        }

        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let meta = result.meta,
              let price = meta.regularMarketPrice else {
            throw PriceError.notFound
        }

        let prev = meta.chartPreviousClose ?? meta.previousClose ?? price
        // London-listed instruments are quoted in pence (GBp), not pounds.
        // Normalise to GBP so downstream code can treat the currency as a
        // first-class ISO code and FX rates work straight from Frankfurter.
        let rawCurrency = meta.currency ?? ""
        let isPence = rawCurrency == "GBp"
        let currency = isPence ? "GBP" : rawCurrency.uppercased()
        let normalisedPrice = isPence ? price / 100 : price
        let normalisedPrev = isPence ? prev / 100 : prev
        return Quote(
            symbol: meta.symbol ?? symbol,
            price: normalisedPrice,
            previousClose: normalisedPrev,
            currency: currency
        )
    }

    private func fetchYahooSearch(query: String) async throws -> [SymbolMatch] {
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "10"),
            URLQueryItem(name: "newsCount", value: "0"),
            URLQueryItem(name: "enableFuzzyQuery", value: "true")
        ]
        guard let url = components.url else { throw PriceError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PriceError.badResponse
        }

        let decoded = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
        let raw = decoded.quotes ?? []

        return raw.compactMap { item -> SymbolMatch? in
            guard let symbol = item.symbol, !symbol.isEmpty else { return nil }
            // Drop options/futures noise
            if let q = item.quoteType?.uppercased(),
               ["OPTION", "FUTURE", "CRYPTOCURRENCY"].contains(q) == false || q == "EQUITY" || q == "ETF" || q == "MUTUALFUND" || q == "INDEX" || q == "CURRENCY" {
                // pass
            }
            return SymbolMatch(
                symbol: symbol,
                name: item.shortname ?? item.longname ?? "",
                exchange: item.exchDisp ?? item.exchange ?? "",
                type: item.typeDisp ?? item.quoteType ?? "",
                currency: nil
            )
        }
    }
}

enum PriceError: LocalizedError {
    case badURL, badResponse, notFound

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid symbol."
        case .badResponse: return "Price service unavailable."
        case .notFound: return "Symbol not found."
        }
    }
}

// MARK: - Yahoo response shapes

private struct YahooChartResponse: Decodable {
    let chart: Chart
    struct Chart: Decodable {
        let result: [Result]?
        struct Result: Decodable {
            let meta: Meta?
            struct Meta: Decodable {
                let symbol: String?
                let currency: String?
                let regularMarketPrice: Double?
                let previousClose: Double?
                let chartPreviousClose: Double?
            }
        }
    }
}

private struct YahooSearchResponse: Decodable {
    let quotes: [Item]?
    struct Item: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let exchDisp: String?
        let exchange: String?
        let typeDisp: String?
        let quoteType: String?
    }
}
