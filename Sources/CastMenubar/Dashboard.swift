import AppKit
import Foundation
import SwiftUI

// MARK: - Dados

struct WeatherNow: Equatable {
    var city: String
    var temp: Double
    var code: Int
    var isDay: Bool
    var humidity: Int?
    var high: Double?
    var low: Double?

    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

/// Clima atual via Open-Meteo (sem chave). A cidade sai do fuso do próprio Chromecast (ex.: America/Manaus → Manaus).
actor WeatherService {
    private var coords: (city: String, lat: Double, lon: Double)?
    private var cached: (WeatherNow, Date)?

    func current(timezone: String) async -> WeatherNow? {
        if let (w, at) = cached, Date().timeIntervalSince(at) < 15 * 60 { return w }
        if coords == nil {
            let city = timezone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
            guard !city.isEmpty,
                  let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=pt"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = (j["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            coords = (r["name"] as? String ?? city, lat, lon)
        }
        guard let c = coords,
              let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.lat)&longitude=\(c.lon)"
                            + "&current=temperature_2m,weather_code,is_day,relative_humidity_2m"
                            + "&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = j["current"] as? [String: Any] else { return cached?.0 }
        let daily = j["daily"] as? [String: Any]
        let w = WeatherNow(city: c.city,
                           temp: cur["temperature_2m"] as? Double ?? 0,
                           code: cur["weather_code"] as? Int ?? 3,
                           isDay: (cur["is_day"] as? Int ?? 1) == 1,
                           humidity: cur["relative_humidity_2m"] as? Int,
                           high: (daily?["temperature_2m_max"] as? [Double])?.first,
                           low: (daily?["temperature_2m_min"] as? [Double])?.first)
        cached = (w, Date())
        return w
    }
}

// MARK: - Tela (1920×1080)

struct DashboardView: View {
    let now: Date
    let weather: WeatherNow?
    let deviceName: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.85).opacity(0.35), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 1100)
            RadialGradient(colors: [Color(red: 0.9, green: 0.45, blue: 0.3).opacity(0.22), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 1000)

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.sentenceCase(now.formatted(.dateTime.weekday(.wide).day().month(.wide))))
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 300, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.top, -30)
                Spacer()
                HStack(spacing: 32) {
                    if let weather { WeatherCard(w: weather) }
                    Spacer()
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 100)
        }
        .frame(width: 1920, height: 1080)
        .environment(\.colorScheme, .dark)
    }

    /// "quinta-feira, 15 de outubro" → "Quinta-feira, 15 de outubro"
    static func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(.horizontal, 44).padding(.vertical, 36)
            .frame(height: 230)
            .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 2))
    }
}

private struct WeatherCard: View {
    let w: WeatherNow
    var body: some View {
        Card {
            HStack(spacing: 36) {
                Image(systemName: w.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 110))
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.city).font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 92, weight: .semibold, design: .rounded))
                    if let hi = w.high, let lo = w.low {
                        Text("↑\(Int(hi.rounded()))°  ↓\(Int(lo.rounded()))°" + (w.humidity.map { "  ·  \($0)%" } ?? ""))
                            .font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}

@MainActor
enum DashboardRenderer {
    static func png(now: Date, weather: WeatherNow?, deviceName: String) -> Data? {
        let r = ImageRenderer(content: DashboardView(now: now, weather: weather, deviceName: deviceName))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
