import SwiftUI

enum Term {
    static let bg        = Color(hex: 0x1E1E1E)
    static let cardBg    = Color(hex: 0x242424)
    static let border    = Color(hex: 0x333333)
    static let text      = Color(hex: 0xE0E0E0)
    static let dim       = Color(hex: 0x888888)
    static let faint     = Color(hex: 0x555555)
    static let green     = Color(hex: 0x4ADE80)
    static let red       = Color(hex: 0xEA4343)
    static let track     = Color(hex: 0x2A2A2A)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct UsagePopoverView: View {
    @ObservedObject var service: UsageService
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider

            if service.isLoading && service.usage.profile == nil {
                loadingView
            } else if let error = service.usage.error, service.usage.profile == nil {
                errorView(error)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let profile = service.usage.profile {
                            accountCard(profile)
                        }
                        if let limits = service.usage.rateLimits {
                            usageCard(limits)
                        } else {
                            setupCard
                        }
                        statusLineCard
                    }
                    .padding(12)
                }
            }

            divider
            footer
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(Term.bg)
        .task {
            await service.refresh()
            service.startFileMonitor()
            service.startTick()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(">_")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Term.dim)
            Text("cc-hp")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Term.text)
            Spacer()
            if service.isLoading {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 14, height: 14)
                    .colorInvert()
                    .brightness(0.5)
            }
            Button(action: { Task { await service.refresh() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(Term.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Account

    private func accountCard(_ profile: ProfileResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("account", profile.account?.email ?? "-")
            row("org", profile.organization?.name ?? "-")
            HStack(spacing: 0) {
                row("plan", service.usage.planDisplay)
                Spacer()
                row("tier", service.usage.tierDisplay)
            }
            if let status = profile.organization?.subscription_status {
                HStack(spacing: 4) {
                    Text("status")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Term.dim)
                    Text(status)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(status == "active" ? Term.green : Term.red)
                }
            }
        }
        .termCard()
    }

    // MARK: - Usage Card

    private func usageCard(_ limits: RateLimitsFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fiveHour = limits.five_hour {
                gauge(label: "Current Session", pct: fiveHour.used_percentage, resetsAt: fiveHour.resets_at, shortReset: true)
            }

            if limits.five_hour != nil && limits.seven_day != nil {
                Rectangle().fill(Term.border).frame(height: 1)
            }

            if let sevenDay = limits.seven_day {
                gauge(label: "Current Week", pct: sevenDay.used_percentage, resetsAt: sevenDay.resets_at, shortReset: false)

            }

            if let ts = limits.updated_at {
                let date = Date(timeIntervalSince1970: ts)
                Text("synced \(date, style: .relative) ago")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Term.faint)
            }
        }
        .termCard()
    }

    // MARK: - Gauge

    private func gauge(label: String, pct: Double, resetsAt: Double, shortReset: Bool) -> some View {
        let remaining = resetsAt - service.now.timeIntervalSince1970
        let totalWindow: Double = shortReset ? 5 * 3600 : 7 * 24 * 3600
        let elapsed = totalWindow - max(remaining, 0)
        let timePct = min(max(elapsed / totalWindow, 0), 1)
        let pillThreshold: Double = shortReset ? 600 : 86400 // 10min or 1day

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Term.dim)
                Spacer()
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Term.green)
            }

            // Usage bar — segmented, green until 80%, then red
            usageBar(pct: pct)

            // Reset time + countdown pill
            HStack(spacing: 0) {
                Text(shortReset ? formatResetShort(resetsAt) : formatResetLong(resetsAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Term.faint)
                Spacer()
                countdownPill(remaining, threshold: pillThreshold)
            }

            // Time bar — simple green + black
            timeBar(timePct: timePct)
        }
    }

    // Segmented usage bar: green, turns red past 80%. Partial fill on current segment.
    private func usageBar(pct: Double) -> some View {
        let segments = 20
        let progress = Double(segments) * min(max(pct / 100, 0), 1)
        let fullCount = Int(progress)
        let partial = progress - Double(fullCount) // 0.0–1.0 within current segment
        let dangerStart = 16 // 80%

        return HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { i in
                GeometryReader { geo in
                    let color = i >= dangerStart ? Term.red : Term.green
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Term.track)
                        if i < fullCount {
                            RoundedRectangle(cornerRadius: 1).fill(color)
                        } else if i == fullCount && partial > 0 {
                            RoundedRectangle(cornerRadius: 1).fill(color)
                                .frame(width: geo.size.width * partial)
                        }
                    }
                }
                .frame(height: 4)
            }
        }
    }

    // Simple flat green bar for time
    private func timeBar(timePct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Term.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Term.green.opacity(0.35))
                    .frame(width: geo.size.width * timePct)
            }
        }
        .frame(height: 3)
    }

    // Countdown pill: green border when close to reset
    private func countdownPill(_ remaining: Double, threshold: Double) -> some View {
        let isClose = remaining > 0 && remaining < threshold
        let color = isClose ? Term.green : Term.dim

        return Text(formatCountdown(remaining))
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isClose ? Term.green.opacity(0.5) : Term.border, lineWidth: 1)
            )
    }

    // MARK: - Setup Card

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !service.hookInstalled {
                Text("setup required")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Term.text)
                Text("install a statusLine hook to capture\nrate limits from active CC sessions")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Term.dim)
                    .lineSpacing(2)
                Button(action: { service.installHook() }) {
                    Text("install hook")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Term.bg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Term.green, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            } else {
                Text("waiting for data...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Term.dim)
                Text("usage appears after next CC interaction")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Term.faint)
            }
        }
        .termCard()
    }

    // MARK: - Status Line Toggle (square style)

    private var statusLineCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CC Status Line")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Term.text)
                Text("show your quota in cc terminal")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Term.faint)
            }
            Spacer()
            // Square toggle matching terminal aesthetic
            Button(action: { service.setStatusLineEnabled(!service.statusLineEnabled) }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(service.statusLineEnabled ? Term.green.opacity(0.15) : Term.track)
                        .frame(width: 36, height: 18)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(service.statusLineEnabled ? Term.green.opacity(0.5) : Term.border, lineWidth: 1)
                        .frame(width: 36, height: 18)
                    // Knob
                    RoundedRectangle(cornerRadius: 2)
                        .fill(service.statusLineEnabled ? Term.green : Term.faint)
                        .frame(width: 14, height: 12)
                        .offset(x: service.statusLineEnabled ? 8 : -8)
                        .animation(.easeInOut(duration: 0.15), value: service.statusLineEnabled)
                }
            }
            .buttonStyle(.plain)
        }
        .termCard()
    }

    // MARK: - Primitives

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Term.dim)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Term.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var divider: some View {
        Rectangle().fill(Term.border).frame(height: 1)
    }

    private func formatResetShort(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let f = DateFormatter()
        f.dateFormat = "h a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f.string(from: date)
    }

    private func formatResetLong(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' h a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f.string(from: date)
    }

    private func formatCountdown(_ seconds: Double) -> String {
        if seconds <= 0 { return "now" }
        let s = Int(seconds)
        let d = s / 86400
        let h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return String(format: "%ds", sec)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView().scaleEffect(0.6).colorInvert().brightness(0.5)
            Text("fetching...").font(.system(size: 11, design: .monospaced)).foregroundStyle(Term.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text("error").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Term.red)
            Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(Term.dim).multilineTextAlignment(.center)
            Button(action: { Task { await service.refresh() } }) {
                Text("retry").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Term.bg)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Term.dim, in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(12)
    }

    private var footer: some View {
        HStack {
            Text("updated \(service.usage.lastUpdated, style: .relative) ago")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Term.faint)
            Spacer()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("quit").font(.system(size: 10, design: .monospaced)).foregroundStyle(Term.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

extension View {
    func termCard() -> some View {
        self.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Term.cardBg, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.border, lineWidth: 1))
    }
}
