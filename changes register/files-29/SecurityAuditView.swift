import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SecurityAuditView
//
// Sheet unificado de seguridad y auditoría.
// Aglutina 4 dashboards existentes en tabs navegables:
//   1. ZeroKnowledgeLogView   — logs cifrados AES-GCM
//   2. IntegrityDashboardView — verificación SHA-256 de assets
//   3. SecurityDashboardView  — hardening del sistema (AppHardeningManager)
//   4. AuditReportTab         — exportar reporte completo de auditoría
//
// Activado por:
//   .showSecurityLogs  → NotificationCenter (SDPipelineApp.swift menú Seguridad)
//   .exportAuditReport → NotificationCenter (SDPipelineApp.swift menú Seguridad)
//
// También accesible desde SettingsView → Auditoría.

struct SecurityAuditView: View {

    enum Tab: String, CaseIterable {
        case logs       = "Logs Cifrados"
        case integrity  = "Integridad"
        case hardening  = "Hardening"
        case report     = "Reporte"

        var icon: String {
            switch self {
            case .logs:      return "lock.shield.fill"
            case .integrity: return "checkmark.shield.fill"
            case .hardening: return "bolt.shield.fill"
            case .report:    return "doc.badge.checkmark"
            }
        }

        var accentHex: String {
            switch self {
            case .logs:      return "#7c6af7"
            case .integrity: return "#34d399"
            case .hardening: return "#f97316"
            case .report:    return "#60a5fa"
            }
        }
    }

    /// Si se abre directamente en la tab de reporte (desde .exportAuditReport)
    var initialTab: Tab = .logs

    @State private var activeTab: Tab
    @Environment(\.dismiss) private var dismiss

    init(initialTab: Tab = .logs) {
        self.initialTab = initialTab
        _activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            header

            Divider().background(Color.white.opacity(0.07))

            // ── Tab Bar ───────────────────────────────────────────────────
            tabBar

            Divider().background(Color.white.opacity(0.07))

            // ── Content ───────────────────────────────────────────────────
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 640)
        .background(Color(red: 0.07, green: 0.07, blue: 0.10))
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Seguridad y Auditoría")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("Vault protegido · Logs AES-GCM · Session \(ZeroKnowledgeLog.currentSessionID)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab Bar

    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(Color.white.opacity(0.02))
    }

    func tabButton(_ tab: Tab) -> some View {
        let isActive = activeTab == tab
        return Button(action: { activeTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? Color(hex: tab.accentHex) : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isActive
                    ? Color(hex: tab.accentHex).opacity(0.12)
                    : Color.clear
            )
            .cornerRadius(7)
            .overlay(
                isActive
                    ? RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(hex: tab.accentHex).opacity(0.3), lineWidth: 1)
                    : nil
            )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
    }

    // MARK: - Tab Content

    @ViewBuilder
    var tabContent: some View {
        switch activeTab {
        case .logs:
            ZeroKnowledgeLogView()
                .padding(16)
        case .integrity:
            IntegrityDashboardView()
                .padding(16)
        case .hardening:
            SecurityDashboardView()
                .padding(16)
        case .report:
            AuditReportTab()
                .padding(16)
        }
    }
}

// MARK: - AuditReportTab

private struct AuditReportTab: View {

    @State private var report: AuditReport?
    @State private var isGenerating = false
    @State private var exportMsg: String?
    @State private var savePanel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Generate Button ───────────────────────────────────────────
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reporte de Auditoría Completo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Consolida assets, eventos de seguridad, integridad y backup en un solo documento.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: generateReport) {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 12))
                        }
                        Text(isGenerating ? "Generando…" : "Generar Reporte")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#60a5fa"))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))

            // ── Report Content ────────────────────────────────────────────
            if let r = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {

                        // Stats row
                        HStack(spacing: 8) {
                            auditStat("\(r.totalAssets)", "Assets totales", hex: "#7c6af7")
                            auditStat("\(r.approvedAssets)", "Aprobadas", hex: "#34d399")
                            auditStat("\(r.publishedAssets)", "Publicadas", hex: "#60a5fa")
                            auditStat("\(r.securityEvents)", "Eventos seg.", hex: "#f97316")
                            auditStat("\(r.blockedPrompts)", "Prompts bloq.", hex: "#ef4444")
                        }

                        Divider().background(Color.white.opacity(0.08))

                        // Status cards
                        HStack(spacing: 8) {
                            statusCard(
                                icon: r.integrityPassed ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                title: "Integridad",
                                value: r.integrityPassed ? "OK" : "Advertencias",
                                date: r.integrityDate,
                                color: r.integrityPassed ? "#34d399" : "#f97316"
                            )
                            statusCard(
                                icon: r.lastBackupOK ? "externaldrive.badge.checkmark" : "externaldrive.badge.xmark",
                                title: "Último Backup",
                                value: r.lastBackupOK ? "Exitoso" : "Falló",
                                date: r.lastBackupDate,
                                color: r.lastBackupOK ? "#34d399" : "#ef4444"
                            )
                        }

                        Divider().background(Color.white.opacity(0.08))

                        // Raw summary
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RESUMEN DE TEXTO")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .tracking(1.2)

                            ScrollView {
                                Text(r.summaryText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 160)
                            .padding(10)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                        }

                        // Export row
                        HStack(spacing: 8) {
                            if let msg = exportMsg {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(hex: "#34d399"))
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#34d399"))
                            }
                            Spacer()
                            Button(action: { exportJSON(r) }) {
                                Label("Exportar JSON", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#60a5fa"))
                            }
                            .buttonStyle(.plain)

                            Button(action: { exportTXT(r) }) {
                                Label("Exportar TXT", systemImage: "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.clock")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Presiona «Generar Reporte» para consolidar la auditoría")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Subviews

    func auditStat(_ value: String, _ label: String, hex: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: hex))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: hex).opacity(0.08))
        .cornerRadius(8)
    }

    func statusCard(icon: String, title: String, value: String, date: Date?, color: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color(hex: color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(value)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: color))
                if let d = date {
                    Text(d, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(hex: color).opacity(0.06))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: color).opacity(0.2), lineWidth: 1))
    }

    // MARK: - Actions

    func generateReport() {
        isGenerating = true
        Task {
            let r = await AppEnvironment.shared.generateAuditReport()
            await MainActor.run {
                report = r
                isGenerating = false
            }
        }
    }

    func exportJSON(_ r: AuditReport) {
        guard let data = try? JSONEncoder.pretty.encode(r) else { return }
        saveData(data, filename: "audit_report_\(dateStamp()).json", contentType: UTType.json)
    }

    func exportTXT(_ r: AuditReport) {
        guard let data = r.summaryText.data(using: .utf8) else { return }
        saveData(data, filename: "audit_report_\(dateStamp()).txt", contentType: UTType.plainText)
    }

    func saveData(_ data: Data, filename: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes  = [contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        exportMsg = "Exportado: \(url.lastPathComponent)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportMsg = nil }
    }

    func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: Date())
    }
}
