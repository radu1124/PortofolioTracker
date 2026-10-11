//
//  ChartService.swift
//  PortofolioWidget
//
//  Fetches historical close-price series from Yahoo's public chart endpoint.
//  All returned dates are normalized to UTC day-starts so prices from
//  different exchanges (which close at different local times) can be
//  cross-referenced by calendar day.
//

import Foundation

struct HistoricalPrice: Hashable {
    let date: Date
    let close: Double
}

actor ChartService {
    static let shared = ChartService()

    private var cache: [String: (data: [HistoricalPrice], fetchedAt: Date)] = [:]
    private let cacheDuration: TimeInterval = 300

    private static let utcDayCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func history(symbol: String, range: ChartRange) async throws -> [HistoricalPrice] {
        let upper = symbol.uppercased()
        let key = "\(upper)|\(range.rawValue)"
        if let cached = cache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheDuration {
            return cached.data
        }
        do {
            let data = try await fetch(symbol: upper, range: range)
            cache[key] = (data, Date())
            return data
        } catch PriceError.notFound where !upper.contains(".") {
            // Mirror PriceService's BVB suffix fallback so the historical
            // chart works for tickers the user typed without a suffix.
            for suffix in [".RO", ".BVB"] {
                do {
                    let data = try await fetch(symbol: upper + suffix, range: range)
                    cache[key] = (data, Date())
                    return data
                } catch PriceError.notFound {
                    continue
                }
            }
            throw PriceError.notFound
        }
    }

    private func fetch(symbol: String, range: ChartRange) async throws -> [HistoricalPrice] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)")!
        components.queryItems = await [
            URLQueryItem(name: "interval", value: range.interval),
            URLQueryItem(name: "range", value: range.yahooRange)
        ]
        guard let url = components.url else { throw PriceError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PriceError.badResponse
        }

        let decoded = try JSONDecoder().decode(YahooHistoryResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators?.quote?.first?.close,
              timestamps.count == closes.count else {
            throw PriceError.notFound
        }

        let cal = Self.utcDayCalendar
        var prices: [HistoricalPrice] = []
        prices.reserveCapacity(timestamps.count)
        for i in 0..<timestamps.count {
            guard let close = closes[i] else { continue }
            let date = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamps[i])))
            prices.append(HistoricalPrice(date: date, close: close))
        }
        return prices
    }
}

private struct YahooHistoryResponse: Decodable {
    let chart: Chart
    struct Chart: Decodable {
        let result: [Result]?
        struct Result: Decodable {
            let timestamp: [Int]?
            let indicators: Indicators?
            struct Indicators: Decodable {
                let quote: [Quote]?
                struct Quote: Decodable {
                    let close: [Double?]?
                }
            }
        }
    }
}
