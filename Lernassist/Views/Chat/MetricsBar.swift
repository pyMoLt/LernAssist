import SwiftUI

// MARK: - MetricsBar 2.0 (Live Telemetry Capsule, Moving Sparkline & Quick Model Switcher)

/// Organische Telemetrie-Kapsel oben rechts in der Chat-Leiste.
/// Trennt sauber zwischen **Prompt Processing (Prefill)** und **Token Speed (Decode)**,
/// zeigt einen live mitlaufenden Sparkline-Graphen (`Canvas`) und erlaubt im Popover
/// zusätzlich den direkten Modell- und Profilwechsel im selben Fenster.
struct MetricsBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var telemetry: TelemetryStore
    /// Schmales Fenster: nur Prefill- und Decode-tok/s als Zahlen, ohne Graph und Kontextring.
    var compact = false
    @State private var showDetails = false
    @State private var isLoadingModels = false

    var body: some View {
        let metrics = telemetry.metrics
        let isStreaming = viewModel.isStreaming

        Button {
            showDetails.toggle()
            if let profile = viewModel.activeProfile,
               (viewModel.cachedModelsByProfile[profile.id] ?? []).isEmpty {
                refreshModels(for: profile)
            }
        } label: {
            GlassChip {
                HStack(spacing: 7) {
                    statusIndicator(metrics: metrics, isStreaming: isStreaming)

                    if let status = viewModel.backgroundJobStatus {
                        Text(status)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        switch viewModel.lmStudioStatus {
                        case .loading(let m):
                            Text("Lade \(shortModelName(m))…")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DS.Accent.amber)
                                .lineLimit(1)
                        case .unreachable:
                            Text("Server offline")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DS.Accent.rose)
                        case .loaded, .idle:
                            telemetryInlineContent(metrics: metrics, isStreaming: isStreaming)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .help("Live-Telemetrie (Prompt Processing & Token Speed) sowie Schnell-Modellauswahl")
        .accessibilityLabel("Telemetrie und Modell: \(viewModel.activeProfile?.model ?? "kein Modell")")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            detailPopover(metrics: metrics)
        }
        .onAppear {
            if CommandLine.arguments.contains("--open-metrics-popover") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showDetails = true
                }
            }
        }
    }

    // MARK: - Inline-Inhalt der Header-Kapsel

    @ViewBuilder
    private func telemetryInlineContent(metrics: ChatMetrics, isStreaming: Bool) -> some View {
        if compact {
            compactTelemetry(metrics: metrics, isStreaming: isStreaming)
        } else if metrics.isPrefilling && isStreaming {
            // Phase 1: Prompt Processing (Prefill) läuft
            HStack(spacing: 6) {
                Text("Prefill")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Accent.amber)
                if metrics.promptTokens > 0 {
                    Text("\(formatCompactTokens(metrics.promptTokens))")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                TelemetrySparklineView(
                    samples: [],
                    isPrefilling: true,
                    prefillPhase: metrics.prefillElapsed,
                    tint: DS.Accent.amber
                )
                .frame(width: 44, height: 15)
            }
        } else if metrics.totalTokens > 0 || !metrics.tpsHistory.isEmpty || isStreaming {
            // Phase 2: Token Speed (Decode) + Live-Graph + Kontext
            HStack(spacing: 7) {
                if let prefill = metrics.effectivePrefillTPS, !isStreaming {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(String(format: "%.0f", prefill))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(DS.Accent.amber)
                    .help(String(format: "Prompt Processing: %.0f tok/s", prefill))
                }

                if let tps = metrics.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", tps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tpsColor(tps))
                }

                TelemetrySparklineView(
                    samples: metrics.tpsHistory,
                    isPrefilling: false,
                    prefillPhase: 0,
                    tint: tpsColor(metrics.tokensPerSecond ?? 30)
                )
                .frame(width: 48, height: 16)

                if metrics.totalTokens > 0 {
                    let contextSize = viewModel.activeProfile?.contextSizeOverride
                        ?? metrics.contextWindowSize ?? 8192
                    let fillRate = min(1.0, Double(metrics.totalTokens) / Double(max(1, contextSize)))
                    HStack(spacing: 4) {
                        MiniContextRing(progress: fillRate)
                            .frame(width: 11, height: 11)
                        Text(formatCompactTokens(metrics.totalTokens))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(fillRate > 0.85 ? DS.Accent.rose : .secondary)
                    }
                }
            }
        } else {
            // Bereit-Zustand: zeigt kompakten Modellnamen + dezente Sparkline + Dropdown-Pfeil
            HStack(spacing: 6) {
                if let profile = viewModel.activeProfile {
                    Text(shortModelName(profile.model))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TelemetrySparklineView(
                    samples: [],
                    isPrefilling: false,
                    prefillPhase: 0,
                    tint: DS.Accent.emerald
                )
                .frame(width: 34, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Kompakte Variante: ⚡ Prefill-tok/s (orange) · Decode-tok/s (grün).
    @ViewBuilder
    private func compactTelemetry(metrics: ChatMetrics, isStreaming: Bool) -> some View {
        HStack(spacing: 6) {
            if metrics.isPrefilling && isStreaming {
                Text("Prefill")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Accent.amber)
            } else {
                if let prefill = metrics.effectivePrefillTPS {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                        Text(String(format: "%.0f", prefill)).font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(DS.Accent.amber)
                    .help(String(format: "Prompt Processing: %.0f tok/s", prefill))
                }
                if let tps = metrics.tokensPerSecond {
                    Text(String(format: "%.0f tok/s", tps))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tpsColor(tps))
                        .help(String(format: "Token Speed: %.1f tok/s", tps))
                }
            }
        }
    }

    // MARK: - Status-Indikator

    @ViewBuilder
    private func statusIndicator(metrics: ChatMetrics, isStreaming: Bool) -> some View {
        if metrics.isPrefilling && isStreaming {
            Circle()
                .fill(DS.Accent.amber)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(DS.Accent.amber.opacity(0.4), lineWidth: 3)
                )
        } else if viewModel.backgroundJobStatus != nil || isStreaming {
            Circle()
                .fill(DS.Accent.emerald)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(DS.Accent.emerald.opacity(0.35), lineWidth: 3)
                )
        } else {
            switch viewModel.lmStudioStatus {
            case .loading:
                ProgressView().controlSize(.mini)
            case .unreachable:
                Circle().fill(DS.Accent.rose).frame(width: 7, height: 7)
            case .loaded, .idle:
                Circle().fill(DS.Accent.emerald).frame(width: 7, height: 7)
            }
        }
    }

    private func tpsColor(_ tps: Double) -> Color {
        if tps >= 25 { return DS.Accent.emerald }
        if tps >= 10 { return DS.Accent.amber }
        return DS.Accent.rose
    }

    // MARK: - Detail-Popover (Dual-Metrik + Großer Graph + Direkt-Modellauswahl)

    private func detailPopover(metrics: ChatMetrics) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            // 1. Header + Schnell-Modellauswahl im selben Fenster
            popoverModelSwitcherHeader

            SettingsHairline()

            // 2. Zweigeteilte Live-Karten: Prompt Processing (Prefill) vs. Token Speed (Decode)
            HStack(spacing: DS.Space.s) {
                prefillMetricCard(metrics: metrics)
                    .frame(maxWidth: .infinity)
                decodeMetricCard(metrics: metrics)
                    .frame(maxWidth: .infinity)
            }

            // 3. Großer mitlaufender Sparkline-Graph
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Token-Speed (live)", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let maxTps = metrics.tpsHistory.max(), let minTps = metrics.tpsHistory.min(), !metrics.tpsHistory.isEmpty {
                        Text(String(format: "Min %.0f · Peak %.0f tok/s", minTps, maxTps))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(DS.Surface.control)
                    TelemetrySparklineView(
                        samples: metrics.tpsHistory,
                        isPrefilling: metrics.isPrefilling && viewModel.isStreaming,
                        prefillPhase: metrics.prefillElapsed,
                        tint: tpsColor(metrics.tokensPerSecond ?? 30),
                        showGrid: true
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(height: 64)
            }

            // 4. Kontextfenster & KV-Cache
            contextAndCacheSection(metrics: metrics)
        }
        .padding(14)
        // Breit genug für Modell-Umschalter und beide Karten (bei 340 pt wurde links abgeschnitten).
        .frame(width: 380)
    }

    @ViewBuilder
    private var popoverModelSwitcherHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live-Telemetrie & Modell", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if viewModel.isUsingFallback {
                    Text("Fallback aktiv")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Accent.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Accent.amber.opacity(0.14)))
                } else if let profile = viewModel.activeProfile {
                    Label(profile.provider.shortLabel, systemImage: profile.provider.systemImage)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.Accent.brand)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(DS.Accent.brand.opacity(0.12)))
                }
            }

            // Direkte Profil- & Modellauswahl im gleichen Fenster
            if !viewModel.profiles.isEmpty {
                HStack(spacing: 6) {
                    if viewModel.profiles.count > 1 {
                        Menu {
                            ForEach(viewModel.profiles) { p in
                                Button {
                                    viewModel.activeProfileID = p.id
                                    refreshModels(for: p)
                                } label: {
                                    HStack {
                                        Text(p.name)
                                        if p.id == viewModel.activeProfileID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.Accent.brand)
                                Text(viewModel.activeProfile?.name ?? "Profil")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(DS.Surface.control)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let activeIdx = viewModel.profiles.firstIndex(where: { $0.id == viewModel.activeProfileID }) {
                        let profile = viewModel.profiles[activeIdx]
                        let models = viewModel.cachedModelsByProfile[profile.id] ?? []

                        Menu {
                            if models.isEmpty {
                                Text("Keine Modell-Liste geladen")
                            } else {
                                ForEach(models, id: \.id) { m in
                                    Button {
                                        viewModel.profiles[activeIdx].model = m.id
                                        if let cw = m.contextWindow {
                                            viewModel.profiles[activeIdx].contextSizeOverride = cw
                                        }
                                        viewModel.saveSettings()
                                    } label: {
                                        HStack {
                                            Text(m.id)
                                            if m.id == profile.model {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.Accent.emerald)
                                Text(shortModelName(profile.model))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(DS.Surface.control)
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            refreshModels(for: profile)
                        } label: {
                            if isLoadingModels {
                                ProgressView().controlSize(.mini)
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                            .fill(DS.Surface.control)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Verfügbare Modelle vom Server aktualisieren")
                    }
                }
            }
        }
    }

    private func prefillMetricCard(metrics: ChatMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(DS.Accent.amber).frame(width: 6, height: 6)
                Text("PROMPT PROCESSING")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if metrics.isPrefilling && viewModel.isStreaming {
                Text(String(format: "%.1f s…", metrics.prefillElapsed))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.Accent.amber)
            } else if let prefillTps = metrics.effectivePrefillTPS {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.0f", prefillTps))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.Accent.amber)
                    Text("tok/s")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("1. Token (TTFT)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metrics.timeToFirstToken.map { String(format: "%.2f s", $0) } ?? "—")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }

            HStack {
                Text("Prompt-Tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metrics.promptTokens)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(DS.Accent.amber.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .stroke(DS.Accent.amber.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func decodeMetricCard(metrics: ChatMetrics) -> some View {
        let color = tpsColor(metrics.tokensPerSecond ?? 30)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("TOKEN SPEED")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let tps = metrics.tokensPerSecond {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", tps))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                    Text("tok/s")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("Output-Tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metrics.completionTokens)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }

            HStack {
                Text("Gesamtdauer")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metrics.totalDuration.map { String(format: "%.1f s", $0) } ?? (viewModel.isStreaming ? "läuft…" : "—"))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 0.75)
        )
    }

    private func contextAndCacheSection(metrics: ChatMetrics) -> some View {
        let cSize = viewModel.activeProfile?.contextSizeOverride
            ?? metrics.contextWindowSize ?? 8192
        let fill = min(1.0, Double(metrics.totalTokens) / Double(max(1, cSize)))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kontext-Auslastung")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(metrics.totalTokens) / \(cSize) Tokens (\(Int(fill * 100))%)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(fill > 0.85 ? DS.Accent.rose : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Surface.control)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: fill > 0.85
                                    ? [DS.Accent.amber, DS.Accent.rose]
                                    : [DS.Accent.brandLight, DS.Accent.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * fill))
                }
            }
            .frame(height: 6)

            if metrics.cachedTokens > 0 {
                HStack {
                    Label("KV-Cache Treffer", systemImage: "memorychip")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(metrics.cachedTokens) Tokens (\(Int(metrics.cacheHitRate * 100))%)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Accent.emerald)
                }
                .padding(.top, 2)
            }
        }
    }

    private func refreshModels(for profile: EndpointProfile) {
        isLoadingModels = true
        Task {
            _ = await viewModel.loadModelsForProfile(profile)
            await MainActor.run {
                isLoadingModels = false
            }
        }
    }

    private func shortModelName(_ raw: String) -> String {
        let base = raw.split(separator: "/").last.map(String.init) ?? raw
        if base.count > 22 {
            return String(base.prefix(20)) + "…"
        }
        return base
    }

    private func formatCompactTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - TelemetrySparklineView (Mitlaufender Echtzeit-Graph)

struct TelemetrySparklineView: View {
    let samples: [Double]
    let isPrefilling: Bool
    let prefillPhase: Double
    let tint: Color
    var showGrid: Bool = false

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            if showGrid {
                for frac in [0.25, 0.5, 0.75] {
                    var grid = Path()
                    let y = h * frac
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(grid, with: .color(Color.primary.opacity(0.05)), lineWidth: 0.5)
                }
            }

            if isPrefilling {
                // Animierte Prompt-Processing-Welle während der Prefill-Phase
                var wave = Path()
                let steps = 28
                let phase = prefillPhase * 6.0
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let x = CGFloat(t) * w
                    let y = h * 0.5 + CGFloat(sin(t * .pi * 2.5 - phase)) * (h * 0.28)
                    if i == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                    else { wave.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(
                    wave,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
                return
            }

            guard !samples.isEmpty else {
                // Ruhige Baseline wenn noch keine Samples vorliegen
                var base = Path()
                base.move(to: CGPoint(x: 0, y: h * 0.65))
                base.addLine(to: CGPoint(x: w, y: h * 0.65))
                context.stroke(base, with: .color(tint.opacity(0.28)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                return
            }

            let points: [CGPoint]
            let maxVal = max(samples.max() ?? 1, 10)
            let minVal = max(0, (samples.min() ?? 0) * 0.75)
            let span = max(maxVal - minVal, 5)

            if samples.count == 1 {
                let y = h * 0.35
                points = [CGPoint(x: 0, y: y), CGPoint(x: w, y: y)]
            } else {
                points = samples.enumerated().map { idx, val in
                    let x = CGFloat(idx) / CGFloat(samples.count - 1) * (w - 3)
                    let norm = (val - minVal) / span
                    let y = (h - 3) - CGFloat(norm) * (h - 6)
                    return CGPoint(x: x, y: y)
                }
            }

            // Glatter Pfad durch die Punkte
            var linePath = Path()
            linePath.move(to: points[0])
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let midX = (prev.x + curr.x) * 0.5
                linePath.addCurve(
                    to: curr,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: curr.y)
                )
            }

            // Sanfte Verlaufsfläche unter der Kurve
            var areaPath = linePath
            if let last = points.last, let first = points.first {
                areaPath.addLine(to: CGPoint(x: last.x, y: h))
                areaPath.addLine(to: CGPoint(x: first.x, y: h))
                areaPath.closeSubpath()
                context.fill(
                    areaPath,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: h)
                    )
                )
            }

            context.stroke(
                linePath,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

            // Leuchtender Punkt am aktuellen Messwert rechts
            if let last = points.last {
                let dotRect = CGRect(x: last.x - 2.2, y: last.y - 2.2, width: 4.4, height: 4.4)
                context.fill(Path(ellipseIn: dotRect), with: .color(tint))
            }
        }
    }
}

// MARK: - MiniContextRing

private struct MiniContextRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: max(0.06, min(1.0, progress)))
                .stroke(
                    progress > 0.85 ? DS.Accent.rose : DS.Accent.cyan,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}
