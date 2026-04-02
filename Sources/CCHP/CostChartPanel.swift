import SwiftUI

/// The floating chart panel shown to the right of the main popover.
struct CostChartPanel: View {
    @ObservedObject var service: UsageService
    @ObservedObject var controller: CostPanelController
    @State private var hoveredBarIndex: Int? = nil

    var body: some View {
        let days = service.last14Days
        let maxCost = days.map(\.totalCost).max() ?? 1
        let hasApi = days.contains { $0.api_cost > 0 }
        let total14 = days.reduce(0) { $0 + $1.totalCost }

        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack(alignment: .firstTextBaseline) {
                Text("14-Day Cost")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Term.text)
                Spacer()
                Text("$\(String(format: "%.2f", total14))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Term.green)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // ── Chart ──
            ZStack(alignment: .bottom) {
                // Grid lines
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Spacer()
                        if i < 3 {
                            Rectangle().fill(Term.border.opacity(0.4)).frame(height: 1)
                        }
                    }
                }
                .frame(height: 110)
                .padding(.horizontal, 14)

                // Bars
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(days.enumerated()), id: \.0) { index, day in
                        chartBar(day: day, maxCost: maxCost, isHovered: hoveredBarIndex == index)
                            .onHover { h in
                                withAnimation(.easeOut(duration: 0.08)) {
                                    hoveredBarIndex = h ? index : nil
                                }
                            }
                    }
                }
                .frame(height: 110)
                .padding(.horizontal, 14)
            }

            // ── X-axis ──
            HStack {
                Text(formatChartDate(days.first?.date ?? ""))
                Spacer()
                Text(formatChartDate(days.last?.date ?? ""))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Term.faint)
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // ── Divider ──
            Rectangle().fill(Term.border).frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            // ── Tooltip / Summary ──
            Group {
                if let idx = hoveredBarIndex, idx < days.count {
                    tooltipArea(day: days[idx])
                } else {
                    defaultSummary(days: days, total: total14)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40, alignment: .top)

            // ── Legend ──
            if hasApi {
                HStack(spacing: 12) {
                    legendDot(color: Term.green, label: "Subscription")
                    legendDot(color: Term.green.opacity(0.5), label: "API Extra")
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }

            // ── Extra Usage ──
            if let extra = service.extraUsage, extra.isEnabled == true,
               let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Rectangle().fill(Term.border).frame(height: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                extraUsageBar(used: used, limit: limit)
                    .padding(.horizontal, 14)
            }

            Spacer().frame(height: 12)
        }
        .frame(width: 300)
        .background(Term.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    // MARK: - Bar

    private func chartBar(day: DailyCost, maxCost: Double, isHovered: Bool) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // API extra segment (lighter green)
                if day.api_cost > 0 && maxCost > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Term.green.opacity(isHovered ? 0.6 : 0.3))
                        .frame(height: max(geo.size.height * day.api_cost / maxCost, 1))
                }
                // Main segment
                if day.cost > 0 && maxCost > 0 {
                    let barHeight = max(geo.size.height * day.cost / maxCost, 2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Term.green.opacity(isHovered ? 0.9 : 0.45))
                        .frame(height: barHeight)
                }
                if day.totalCost == 0 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Term.track)
                        .frame(height: 2)
                }
            }
        }
    }

    // MARK: - Tooltip

    private func tooltipArea(day: DailyCost) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(formatChartDate(day.date))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Term.text)
                Text(": ")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Term.faint)
                Text("$\(String(format: "%.2f", day.totalCost))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Term.green)
                Text(" · \(formatTokens(day.totalTokens)) tokens")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Term.dim)
            }

            let topModels = day.models.sorted { $0.cost > $1.cost }.prefix(2)
            ForEach(Array(topModels.enumerated()), id: \.0) { _, m in
                HStack(spacing: 0) {
                    Text("  \(shortModel(m.model))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Term.faint)
                    Text(" $\(String(format: "%.2f", m.cost))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Term.dim)
                    Text(" · \(formatTokens(m.tokens))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Term.faint)
                }
            }

            if day.api_cost > 0 {
                Text("  API: $\(String(format: "%.2f", day.api_cost)) · \(formatTokens(day.api_tokens))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Term.green.opacity(0.5))
            }
        }
    }

    private func defaultSummary(days: [DailyCost], total: Double) -> some View {
        let totalTokens = days.reduce(Int64(0)) { $0 + $1.totalTokens }
        let avgDaily = total / 14.0
        return VStack(alignment: .leading, spacing: 2) {
            Text("$\(String(format: "%.2f", total)) total · \(formatTokens(totalTokens)) tokens")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Term.dim)
            Text("~$\(String(format: "%.2f", avgDaily))/day avg")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Term.faint)
        }
    }

    // MARK: - Extra Usage Bar

    private func extraUsageBar(used: Double, limit: Double) -> some View {
        let usedUSD = used / 100
        let limitUSD = limit / 100
        let pct = limitUSD > 0 ? min(usedUSD / limitUSD, 1.0) : 0

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extra Usage")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Term.dim)
                Spacer()
                Text("$\(String(format: "%.2f", usedUSD)) / $\(String(format: "%.0f", limitUSD))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Term.green.opacity(0.5))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Term.track)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Term.green.opacity(0.5).opacity(0.6))
                        .frame(width: geo.size.width * pct)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Helpers

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Term.faint)
        }
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func formatChartDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return dateStr }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard m >= 1, m <= 12 else { return dateStr }
        return "\(months[m]) \(d)"
    }

    private func shortModel(_ name: String) -> String {
        name.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
    }
}
