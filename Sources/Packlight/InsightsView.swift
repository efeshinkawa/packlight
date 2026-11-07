import Charts
import SwiftUI

/// Battery forecast, what's draining it, and what to do about it.
struct InsightsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var insights: Insights
    @AppStorage(Key.language) private var language = Lang.system.rawValue
    @State private var hours = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                forecast
                if !insights.recommendations.isEmpty { recommendations }
                consumers
                chart
                batteryFacts
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 480)
        .environment(\.layoutDirection, Lang.current.isRTL ? .rightToLeft : .leftToRight)
    }

    // MARK: Forecast

    private var forecast: some View {
        HStack(spacing: 12) {
            if let b = insights.battery {
                tile(T("Battery"), "\(b.percent)%",
                     b.onAC ? (b.charging ? T("Charging") : T("On power")) : T("On battery"))
                if let m = insights.minutesLeft {
                    tile(T("Time left"), MenuView.duration(m),
                         T("at the current draw"))
                } else {
                    tile(T("Time left"), "—",
                         b.onAC ? T("unplug to estimate") : T("measuring…"))
                }
                if let w = insights.averageWatts {
                    tile(T("Draw"), String(format: "%.1f W", w),
                         insights.percentPerHour.map { T("−%d%% per hour", Int($0.rounded())) } ?? "")
                }
                if let h = insights.fullChargeHours {
                    tile(T("Full charge"), T("%.1f h", h),
                         T("would last at this rate"))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Recommendations

    private var recommendations: some View {
        section(T("Recommendations")) {
            ForEach(insights.recommendations) { r in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: r.kind == .warning ? "exclamationmark.triangle.fill"
                          : r.kind == .action ? "wand.and.stars" : "lightbulb.fill")
                        .foregroundStyle(r.kind == .warning ? .orange : r.kind == .action ? .green : .yellow)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        Text(r.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let fix = r.fix {
                        Button(fixTitle(fix)) { state.apply(fix) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func fixTitle(_ fix: Recommendation.Fix) -> String {
        switch fix {
        case .switchAway: return T("Go Away")
        case .lowPower: return T("Turn on")
        case .installHelper: return T("Set up")
        case .addToAway: return T("Add")
        }
    }

    // MARK: Consumers

    private var consumers: some View {
        section(T("What's using energy (last ~15 min)")) {
            if insights.consumers.isEmpty {
                Text(T("Measuring…")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(insights.consumers) { c in
                HStack(spacing: 10) {
                    Text(c.name).lineLimit(1).truncationMode(.middle)
                        .frame(width: 170, alignment: .leading)
                    ProgressView(value: c.share)
                        .tint(c.awayCloses ? .green : .orange)
                    Text("\(Int((c.share * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    Image(systemName: c.awayCloses ? "leaf.fill" : "circle")
                        .foregroundStyle(c.awayCloses ? .green : .secondary.opacity(0.4))
                        .help(c.awayCloses ? T("Away mode closes this")
                                           : T("Away mode leaves this running"))
                }
                .font(.callout)
            }
            if insights.awayShare > 0 {
                Text(T("Away mode would close about %d%% of this.", Int((insights.awayShare * 100).rounded())))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let points = insights.history.filter { $0.t >= since }
        return section(T("History")) {
            Picker("", selection: $hours) {
                Text(T("6 h")).tag(6)
                Text(T("24 h")).tag(24)
                Text(T("48 h")).tag(48)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            if points.count < 2 {
                Text(T("Collecting data — check back in a few minutes."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(points, id: \.t) { p in
                    AreaMark(x: .value("Time", p.t), y: .value("%", p.percent))
                        .foregroundStyle(.linearGradient(colors: [.green.opacity(0.35), .green.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.t), y: .value("%", p.percent))
                        .foregroundStyle(.green)
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel(T("Battery %%"))
                .frame(height: 140)

                Chart(points.filter { !$0.onAC }, id: \.t) { p in
                    BarMark(x: .value("Time", p.t, unit: .minute), y: .value("W", p.watts))
                        .foregroundStyle(p.watts >= 9 ? .orange : .blue)
                }
                .chartYAxisLabel(T("Watts on battery"))
                .frame(height: 110)
            }
        }
    }

    // MARK: Battery facts

    private var batteryFacts: some View {
        section(T("Battery")) {
            if let b = insights.battery {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    fact(T("Health"), "\(Int((b.health * 100).rounded()))%  (\(Int(b.fullMAh)) / \(Int(b.designMAh)) mAh)")
                    fact(T("Cycles"), "\(b.cycles)")
                    fact(T("Energy left"), String(format: "%.1f / %.1f Wh", b.remainingWh, b.fullWh))
                    fact(T("Instant draw"), String(format: "%.2f W  (%.2f V × %.2f A)", b.watts, b.voltage, abs(b.amperage)))
                    if let t = b.temperatureC { fact(T("Temperature"), String(format: "%.1f °C", t)) }
                    if let s = insights.stats {
                        fact(T("Memory"), T("%.1f of %.0f GB, swap %.1f GB", s.memUsedGB, s.memTotalGB, s.swapUsedGB))
                    }
                }
                .font(.callout)
                Text(T("Time left blends a smoothed live reading with the actual energy drop over the last 30 minutes."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
