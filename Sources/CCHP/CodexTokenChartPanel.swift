import SwiftUI

struct CodexTokenChartPanel: View {
    @ObservedObject var service: UsageService
    @ObservedObject var controller: CodexTokenPanelController
    @State private var hoveredBarIndex: Int? = nil

    var body: some View {
        let days = service.codexLast14Days
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)
        let total14 = days.reduce(Int64(0)) { $0 + $1.tokens }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("14-Day Token Burn")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Term.text)
                Spacer()
                Text(formatTokens(total14))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Term.green)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ZStack(alignment: .bottom) {
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

                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(days.enumerated()), id: \.0) { index, day in
                        tokenBar(day: day, maxTokens: maxTokens, isHovered: hoveredBarIndex == index)
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

            HStack {
                Text(formatChartDate(days.first?.date ?? ""))
                Spacer()
                Text(formatChartDate(days.last?.date ?? ""))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Term.faint)
            .padding(.horizontal, 14)
            .padding(.top, 4)

            Rectangle().fill(Term.border).frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Group {
                if let idx = hoveredBarIndex, idx < days.count {
                    tooltipArea(day: days[idx])
                } else {
                    defaultSummary(days: days, total: total14)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40, alignment: .top)

            Spacer().frame(height: 12)
        }
        .frame(width: 300)
        .background(Term.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    private func tokenBar(day: CodexDailyTokens, maxTokens: Int64, isHovered: Bool) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if day.tokens > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Term.green.opacity(isHovered ? 0.9 : 0.45))
                        .frame(height: max(geo.size.height * Double(day.tokens) / Double(maxTokens), 2))
                } else {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Term.track)
                        .frame(height: 2)
                }
            }
        }
    }

    private func tooltipArea(day: CodexDailyTokens) -> some View {
        HStack(spacing: 0) {
            Text(formatChartDate(day.date))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Term.text)
            Text(": ")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Term.faint)
            Text("\(formatTokens(day.tokens)) tokens")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Term.green)
        }
    }

    private func defaultSummary(days: [CodexDailyTokens], total: Int64) -> some View {
        let avgDaily = total / 14
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(formatTokens(total)) tokens total")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Term.dim)
            Text("~\(formatTokens(avgDaily))/day avg")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Term.faint)
        }
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
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
}
