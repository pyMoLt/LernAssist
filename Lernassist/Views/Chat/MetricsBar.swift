import SwiftUI

// MARK: - MetricsBar

/// Kompakter Status-Chip in der Chat-Leiste. Zeigt live Tokens/Sekunde (farbkodiert),
/// Token-Usage und ein aufklappbares Detail-Popover mit TTFT, Gesamtdauer, Provider-Info.
struct MetricsBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showDetails = false

    var body: some View {
        let metrics = viewModel.currentMetrics
        let isStreaming = viewModel.isStreaming

        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                statusIndicator

                if let status = viewModel.backgroundJobStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    // LM Studio Lade-Status (nur während des Ladens / bei Fehler)
                    switch viewModel.lmStudioStatus {
                    case .loading(let m):
                        Text("Lade \(m.split(separator: "/").last.map(String.init) ?? m)…")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .italic()
                    case .unreachable:
                        Text("LM Studio nicht erreichbar")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    case .loaded, .idle:
                        if metrics.totalTokens > 0 || isStreaming {
                            // Tok/s — grün/gelb/orange je nach Speed
                            if let tps = metrics.tokensPerSecond {
                                Text(String(format: "%.0f tok/s", tps))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(tpsColor(tps))
                            }
                            // Token-Zähler / Kontext-Limit
                            if metrics.totalTokens > 0 {
                                let contextSize = viewModel.activeProfile?.contextSizeOverride
                                    ?? metrics.contextWindowSize ?? 8192
                                let fillRate = min(1.0, Double(metrics.totalTokens) / Double(contextSize))
                                Text("\(metrics.totalTokens)/\(contextSize)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(fillRate > 0.85 ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            // Liquid-Glass-Chip (Phase G): passt zum Rest der Chat-Leiste; die Zwischenablage-
            // Hintergrundfarbe wurde durch das echte glassEffect ersetzt.
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.backgroundJobStatus == nil && metrics.totalTokens == 0 && !isStreaming
                  && viewModel.lmStudioStatus == .idle)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            detailPopover(metrics: metrics)
        }
    }

    // MARK: - Status-Indikator

    @ViewBuilder
    private var statusIndicator: some View {
        if viewModel.backgroundJobStatus != nil || viewModel.isStreaming {
            ProgressView().controlSize(.mini)
        } else {
            switch viewModel.lmStudioStatus {
            case .loading:
                ProgressView().controlSize(.mini)
            case .unreachable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .idle:
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - TPS Farbkodierung

    private func tpsColor(_ tps: Double) -> Color {
        if tps >= 30 { return .green }
        if tps >= 10 { return Color(red: 0.85, green: 0.65, blue: 0.0) } // Dunkelgelb
        return .orange
    }

    // MARK: - Detail-Popover

    private func detailPopover(metrics: ChatMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header mit Provider-Info
            HStack {
                Text("Metriken").font(.headline)
                Spacer()
                if let profile = viewModel.activeProfile {
                    Label(profile.provider.shortLabel, systemImage: profile.provider.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Divider()

            // Geschwindigkeit
            if let tps = metrics.tokensPerSecond {
                metricRow("Geschwindigkeit",
                          String(format: "%.1f Tok/s", tps),
                          color: tpsColor(tps))
            }
            if let ttft = metrics.timeToFirstToken {
                metricRow("Zeit bis 1. Token", String(format: "%.2f s", ttft))
            }
            if let total = metrics.totalDuration {
                metricRow("Gesamtdauer", String(format: "%.1f s", total))
            }

            if metrics.tokensPerSecond != nil || metrics.timeToFirstToken != nil {
                Divider()
            }

            // Token-Zähler
            metricRow("Prompt Tokens", "\(metrics.promptTokens)")
            metricRow("Output Tokens", "\(metrics.completionTokens)")
            metricRow("Gesamt", "\(metrics.totalTokens)")

            if metrics.cachedTokens > 0 {
                metricRow("KV-Cache Hits",
                          "\(metrics.cachedTokens) (\(Int(metrics.cacheHitRate * 100))%)",
                          color: .green)
            }

            let cSize = viewModel.activeProfile?.contextSizeOverride
                ?? metrics.contextWindowSize ?? 8192
            metricRow("Kontext-Limit", "\(cSize) Tokens")

            // Quelle der TPS
            if let _ = metrics.tokensPerSecond, let profile = viewModel.activeProfile {
                Divider()
                metricRow("TPS-Quelle", tpsSource(for: profile), color: .secondary)
            }

            if viewModel.isUsingFallback {
                Divider()
                metricRow("Profil", "Fallback aktiv ⚠️", color: .orange)
            }

            // LM Studio Status
            switch viewModel.lmStudioStatus {
            case .loading(let m):
                Divider()
                metricRow("LM Studio", "Lädt \(m.split(separator: "/").last.map(String.init) ?? m)…", color: .orange)
            case .unreachable:
                Divider()
                metricRow("LM Studio", "Nicht erreichbar — bitte starten", color: .red)
            case .loaded:
                Divider()
                metricRow("LM Studio", "Modell geladen ✔️", color: .green)
            case .idle:
                EmptyView()
            }
        }
        .font(.caption)
        .padding(12)
        .frame(minWidth: 280)
    }

    private func metricRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).foregroundColor(color)
        }
    }

    private func tpsSource(for profile: EndpointProfile) -> String {
        switch profile.provider {
        case .lmStudioNative: return "Server (LM Studio stats)"
        case .ollama:         return "Server (eval_count/duration)"
        case .openAICompatible where profile.baseURL.contains("groq"):
            return "Server (Groq completion_time)"
        default:              return "Clientseitig (geschätzt)"
        }
    }
}
