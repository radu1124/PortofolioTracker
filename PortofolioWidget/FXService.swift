//
//  FXService.swift
//  PortofolioWidget
//
//  Free FX rate provider using api.frankfurter.app (ECB reference rates).
//  No API key. Supports both latest and historical rates. If a non-business
//  date is requested, Frankfurter returns the most recent preceding business
//  day's rates automatically.
//

import Foundation

actor FXService {
    static let shared = FXService()

    /// Returns: 1 unit of `base` equals X units of each returned currency.
    func latest(base: String) async throws -> (date: String, rates: [String: Double]) {
        var components = URLComponents(string: "https://api.frankfurter.app/latest")!
        components.queryItems = [URLQueryItem(name: "from", value: base.uppercased())]
        guard let url = components.url else { throw FXError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FXError.badResponse
        }
        let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
        return (decoded.date, decoded.rates)
    }

    /// Historical rates for `date` (yyyy-MM-dd), 1 unit of `base` to each target.
    func historical(date: String, base: String) async throws -> (date: String, rates: [String: Double]) {
        var components = URLComponents(string: "https://api.frankfurter.app/\(date)")!
        components.queryItems = [URLQueryItem(name: "from", value: base.uppercased())]
        guard let url = components.url else { throw FXError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FXError.badResponse
        }
        let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
        return (decoded.date, decoded.rates)
    }
}

enum FXError: Error {
    case badURL, badResponse
}

private struct FrankfurterResponse: Decodable {
    let base: String
    let date: String
    let rates: [String: Double]
}
