//
//  InflationService.swift
//  PortofolioWidget
//
//  Fetches monthly CPI series from FRED (Federal Reserve Economic Data).
//
//  Endpoint: https://api.stlouisfed.org/fred/series/observations
//  Params : series_id, api_key, file_type=json, frequency=m, units=lin,
//           observation_start (yyyy-MM-dd)
//
//  Get a free API key at:
//    https://fred.stlouisfed.org/docs/api/api_key.html
//  and paste it into PortofolioWidget/Secrets.swift (gitignored; copy it
//  from Secrets.example.swift at the repo root).
//

import Foundation

actor InflationService {
    static let shared = InflationService()

    // MARK: - API key
    private let fredAPIKey = Secrets.fredAPIKey

    private var cache: [String: [CPIObservation]] = [:]
    private let session: URLSession = .shared

    enum InflationError: Error, LocalizedError {
        case missingAPIKey
        case badResponse(status: Int, message: String?)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Set your FRED API key in InflationService.swift."
            case .badResponse(let status, let msg):
                return msg ?? "FRED returned HTTP \(status)."
            case .decodingFailed:
                return "Couldn't parse FRED response."
            }
        }
    }

    /// Returns CPI observations for the given FRED series, sorted ascending.
    /// Memoised per-session.
    func cpiSeries(series seriesID: String) async throws -> [CPIObservation] {
        if let hit = cache[seriesID], !hit.isEmpty { return hit }

        guard !fredAPIKey.isEmpty, fredAPIKey != "REPLACE_WITH_YOUR_FRED_API_KEY" else {
            throw InflationError.missingAPIKey
        }

        // Pull the last ~10 years monthly. Plenty for any chart range we
        // support; FRED responses stay small (~120 rows) so no need to be
        // clever about the window.
        let calendar = Calendar(identifier: .gregorian)
        let startYear = calendar.component(.year, from: Date()) - 10

        var comps = URLComponents(string: "https://api.stlouisfed.org/fred/series/observations")!
        comps.queryItems = [
            .init(name: "series_id",         value: seriesID),
            .init(name: "api_key",           value: fredAPIKey),
            .init(name: "file_type",         value: "json"),
            .init(name: "frequency",         value: "m"),
            .init(name: "units",             value: "lin"),
            .init(name: "observation_start", value: "\(startYear)-01-01")
        ]
        let url = comps.url!

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw InflationError.badResponse(status: -1, message: nil)
        }
        guard http.statusCode == 200 else {
            // FRED returns a JSON body with `error_message` on failure.
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = body?["error_message"] as? String
            throw InflationError.badResponse(status: http.statusCode, message: msg)
        }

        let decoded: FREDResponse
        do {
            decoded = try JSONDecoder().decode(FREDResponse.self, from: data)
        } catch {
            throw InflationError.decodingFailed
        }

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.locale = Locale(identifier: "en_US_POSIX")
        let utcCal: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()

        var obs: [CPIObservation] = []
        for row in decoded.observations {
            // FRED encodes missing values as ".".
            guard let v = Double(row.value) else { continue }
            guard let d = parser.date(from: row.date) else { continue }
            let comps = utcCal.dateComponents([.year, .month], from: d)
            guard let y = comps.year, let m = comps.month else { continue }
            obs.append(CPIObservation(year: y * 100 + m, value: v))
        }
        obs.sort { $0.year < $1.year }
        cache[seriesID] = obs

        if let first = obs.first, let last = obs.last {
            print("[Inflation/FRED] \(seriesID): \(obs.count) obs, \(first.year)→\(last.year), \(String(format: "%.2f", first.value))→\(String(format: "%.2f", last.value))")
            if obs.count >= 13 {
                let yoy = (last.value / obs[obs.count - 13].value - 1) * 100
                print("[Inflation/FRED] \(seriesID) YoY: \(String(format: "%+.2f%%", yoy))")
            }
        }

        return obs
    }
}

private struct FREDResponse: Decodable, Sendable {
    struct Observation: Decodable, Sendable {
        let date: String
        let value: String
    }
    let observations: [Observation]
}

// MARK: - Bond yields
//
// Same FRED API, different endpoint use: we just ask for the latest valid
// observation per series. Lives in this file because it reuses the FRED key.

actor BondYieldService {
    static let shared = BondYieldService()

    private let fredAPIKey = Secrets.fredAPIKey
    private var cache: [String: BondYield] = [:]
    private let session: URLSession = .shared

    /// Dispatch to the right backend based on the country's source. Use
    /// this from callers; the source-specific methods are mainly internal.
    func latestYield(for country: BondCountry) async throws -> BondYield {
        switch country.source {
        case .fred: return try await latestFREDYield(seriesID: country.seriesID)
        case .ecb:  return try await latestECBYield(seriesKey: country.seriesID)
        }
    }

    private func latestFREDYield(seriesID: String) async throws -> BondYield {
        if let hit = cache[seriesID] { return hit }

        var comps = URLComponents(string: "https://api.stlouisfed.org/fred/series/observations")!
        comps.queryItems = [
            .init(name: "series_id",  value: seriesID),
            .init(name: "api_key",    value: fredAPIKey),
            .init(name: "file_type",  value: "json"),
            .init(name: "sort_order", value: "desc"),
            .init(name: "limit",      value: "20")
        ]

        let (data, response) = try await session.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(FREDResponse.self, from: data)
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.locale = Locale(identifier: "en_US_POSIX")

        // FRED returns observations DESC; take the first valid one (some
        // series have trailing "." placeholders before the latest print
        // arrives).
        for row in decoded.observations {
            guard let v = Double(row.value), let d = parser.date(from: row.date) else { continue }
            let y = BondYield(value: v, date: d)
            cache[seriesID] = y
            print("[Bonds/FRED] \(seriesID): \(String(format: "%.2f%%", v)) as of \(row.date)")
            return y
        }
        throw URLError(.cannotParseResponse)
    }

    /// ECB Statistical Data Warehouse (Maastricht convergence yields).
    /// Uses the CSV endpoint because SDMX-JSON is overkill for one number.
    private func latestECBYield(seriesKey: String) async throws -> BondYield {
        if let hit = cache[seriesKey] { return hit }

        let url = URL(string: "https://data-api.ecb.europa.eu/service/data/IRS/\(seriesKey)?format=csvdata&lastNObservations=1")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }

        // CSV: first row is header, second row is the latest observation.
        // We need OBS_VALUE and TIME_PERIOD columns by index — column count
        // and ordering can shift, so resolve by header name.
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { throw URLError(.cannotParseResponse) }
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        let row    = lines[1].split(separator: ",", omittingEmptySubsequences: false).map { String($0) }

        guard let valueIdx = header.firstIndex(of: "OBS_VALUE"),
              let timeIdx  = header.firstIndex(of: "TIME_PERIOD"),
              valueIdx < row.count, timeIdx < row.count,
              let v = Double(row[valueIdx]) else {
            throw URLError(.cannotParseResponse)
        }

        // TIME_PERIOD is "yyyy-MM" for monthly series.
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.locale = Locale(identifier: "en_US_POSIX")
        let date = parser.date(from: row[timeIdx]) ?? Date()

        let y = BondYield(value: v, date: date)
        cache[seriesKey] = y
        print("[Bonds/ECB] \(seriesKey): \(String(format: "%.2f%%", v)) as of \(row[timeIdx])")
        return y
    }
}
