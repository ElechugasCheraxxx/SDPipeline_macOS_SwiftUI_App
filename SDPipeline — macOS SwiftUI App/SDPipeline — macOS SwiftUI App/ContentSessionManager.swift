import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ContentSessionManager
//
// Motor narrativo para sets temáticos.
// Agrupa generaciones en "sesiones de contenido" (shoots) con:
//   - Nombre, descripción y tag único por sesión
//   - Assets asociados (referencias a IDs de GeneratedAsset)
//   - Settings base compartidos (checkpoint, LoRAs, estilo)
//   - Planning de contenido (número target, plataforma, temática)
//   - Estadísticas de sesión (aprobación, tiempo, ratings)
//
// ROADMAP: "Motor narrativo para sets temáticos" (🟡 MEDIO PLAZO)

@MainActor
final class ContentSessionManager: ObservableObject {

    static let shared = ContentSessionManager()
    private init() { loadAll() }

    // MARK: - Models

    struct ContentSession: Codable, Identifiable, Hashable {
        var id:          UUID    = UUID()
        var tag:         String              // Identificador corto (ej. "beach_editorial_v1")
        var title:       String             // "Beach Editorial Marzo 2025"
        var description: String = ""
        var category:    SessionCategory = .editorial
        var platform:    TargetPlatform  = .onlyfans
        var createdAt:   Date   = Date()
        var closedAt:    Date?  = nil       // nil = sesión abierta
        var isActive:    Bool   = true

        // Planning
        var targetAssetCount:  Int    = 20
        var targetRating:      Int    = 4   // rating mínimo para aprobar
        var contentNotes:      String = ""

        // Settings base de la sesión
        var baseCheckpoint:   String  = ""
        var baseSessionTag:   String  = ""  // Para filtrar en galería
        var baseLoRAs:        [String] = []

        // Assets (IDs de GeneratedAsset)
        var assetIDs: [UUID] = []

        // Estadísticas computadas (refrescadas en memoria, no persistidas)
        var assetCount:    Int    = 0
        var approvedCount: Int    = 0
        var averageRating: Double = 0
        var duration:      TimeInterval { (closedAt ?? Date()).timeIntervalSince(createdAt) }

        var progressPercent: Double {
            targetAssetCount > 0 ? min(1.0, Double(assetCount) / Double(targetAssetCount)) : 0
        }

        var approvalRate: Double {
            assetCount > 0 ? Double(approvedCount) / Double(assetCount) : 0
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: ContentSession, rhs: ContentSession) -> Bool { lhs.id == rhs.id }

        enum SessionCategory: String, Codable, CaseIterable {
            case editorial  = "Editorial"
            case artistic   = "Artístico"
            case commercial = "Comercial"
            case themed     = "Temático"
            case test       = "Test / Experimento"

            var icon: String {
                switch self {
                case .editorial:  return "camera.aperture"
                case .artistic:   return "paintpalette"
                case .commercial: return "bag.fill"
                case .themed:     return "theatermasks.fill"
                case .test:       return "flask.fill"
                }
            }
        }

        enum TargetPlatform: String, Codable, CaseIterable {
            case onlyfans  = "OnlyFans"
            case instagram = "Instagram"
            case patreon   = "Patreon"
            case fansly    = "Fansly"
            case portfolio = "Portfolio"
            case internal_ = "Interno"

            var icon: String {
                switch self {
                case .onlyfans:  return "heart.circle.fill"
                case .instagram: return "camera.fill"
                case .patreon:   return "person.2.fill"
                case .fansly:    return "star.circle.fill"
                case .portfolio: return "rectangle.stack.fill"
                case .internal_: return "lock.fill"
                }
            }
        }
    }

    // MARK: - State

    @Published var sessions:       [ContentSession] = []
    @Published var activeSession:  ContentSession?  = nil

    // MARK: - Public API — CRUD

    /// Crear nueva sesión de contenido.
    @discardableResult
    func create(
        title:    String,
        category: ContentSession.SessionCategory = .editorial,
        platform: ContentSession.TargetPlatform  = .onlyfans
    ) -> ContentSession {
        let tag = generateTag(from: title)
        var session = ContentSession(
            tag:      tag,
            title:    title,
            category: category,
            platform: platform
        )
        session.baseCheckpoint = CharacterEngine.shared.activeCharacter?.preferredCheckpoint ?? ""
        sessions.insert(session, at: 0)
        saveAll()
        return session
    }

    /// Actualizar sesión existente.
    func update(_ session: ContentSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx] = session
        if activeSession?.id == session.id { activeSession = session }
        saveAll()
    }

    /// Cerrar sesión (marcarla como terminada).
    func close(_ session: ContentSession) {
        var updated = session
        updated.isActive  = false
        updated.closedAt  = Date()
        update(updated)
        if activeSession?.id == session.id { activeSession = nil }
    }

    /// Eliminar sesión (no elimina los assets del disco).
    func delete(_ session: ContentSession) {
        sessions.removeAll { $0.id == session.id }
        if activeSession?.id == session.id { activeSession = nil }
        saveAll()
    }

    /// Activar sesión para generaciones futuras.
    func setActive(_ session: ContentSession?) {
        activeSession = session
    }

    // MARK: - Asset Tracking

    /// Registrar un asset generado en la sesión activa.
    func recordAsset(_ asset: GeneratedAsset) {
        guard let id = asset.id else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSession?.id }) else { return }
        if !sessions[idx].assetIDs.contains(id) {
            sessions[idx].assetIDs.append(id)
        }
        refreshStats(for: sessions[idx].id)
        saveAll()
    }

    /// Actualizar estadísticas de una sesión desde el AssetStore.
    func refreshStats(for sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let tag = sessions[idx].tag
        let assets = AssetStore.shared.search(query: "", sessionTag: tag)
        sessions[idx].assetCount    = assets.count
        sessions[idx].approvedCount = assets.filter { $0.statusEnum == .approved }.count
        let rated = assets.filter { $0.rating > 0 }
        sessions[idx].averageRating = rated.isEmpty ? 0 :
            Double(rated.map { Int($0.rating) }.reduce(0, +)) / Double(rated.count)
        if activeSession?.id == sessionID { activeSession = sessions[idx] }
    }

    /// Refrescar estadísticas de todas las sesiones.
    func refreshAllStats() {
        for session in sessions {
            refreshStats(for: session.id)
        }
    }

    // MARK: - Queries

    var activeSessions: [ContentSession] {
        sessions.filter { $0.isActive }
    }

    var closedSessions: [ContentSession] {
        sessions.filter { !$0.isActive }
    }

    func session(forTag tag: String) -> ContentSession? {
        sessions.first { $0.tag == tag }
    }

    // MARK: - Planning Report

    struct SessionReport {
        let session:       ContentSession
        let assets:        [GeneratedAsset]
        let readyToExport: [GeneratedAsset]
        let missing:       Int
        let recommendation: String
    }

    func generateReport(for session: ContentSession) -> SessionReport {
        let assets = AssetStore.shared.search(query: "", sessionTag: session.tag)
        let ready  = assets.filter { Int($0.rating) >= session.targetRating }
        let missing = max(0, session.targetAssetCount - ready.count)

        let recommendation: String
        if missing == 0 {
            recommendation = "✅ Sesión lista para exportar. \(ready.count) assets aprobados."
        } else if session.approvalRate > 0.6 {
            recommendation = "🟡 Buen ritmo. Genera \(missing) assets más para completar el set."
        } else {
            recommendation = "🔴 Tasa de aprobación baja (\(Int(session.approvalRate*100))%). Revisa el prompt y el personaje."
        }

        return SessionReport(
            session:        session,
            assets:         assets,
            readyToExport:  ready,
            missing:        missing,
            recommendation: recommendation
        )
    }

    // MARK: - Persistence

    private var persistenceURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "content_sessions.json")
    }

    private func saveAll() {
        guard let url = persistenceURL else { return }
        if let data = try? JSONEncoder.pretty.encode(sessions) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadAll() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode([ContentSession].self, from: data)
        else { return }
        sessions = decoded
        activeSession = sessions.first { $0.isActive }
    }

    // MARK: - Helpers

    private func generateTag(from title: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        let date = formatter.string(from: Date())
        let base = title.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            .prefix(20)
        return "\(base)_\(date)"
    }
}

// MARK: - SessionPickerView

struct SessionPickerView: View {

    @StateObject private var manager = ContentSessionManager.shared
    @State private var showCreateSheet = false
    @State private var newTitle = ""
    @State private var newCategory: ContentSessionManager.ContentSession.SessionCategory = .editorial
    @State private var newPlatform: ContentSessionManager.ContentSession.TargetPlatform  = .onlyfans

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Sesión activa")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            // Active session indicator
            if let active = manager.activeSession {
                activeSessionRow(active)
            } else {
                Button(action: { showCreateSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#7c6af7").opacity(0.7))
                        Text("Nueva sesión de contenido…")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.06))

            // Recent sessions
            if !manager.activeSessions.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.activeSessions.prefix(5)) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .sheet(isPresented: $showCreateSheet) { createSheet }
    }

    func activeSessionRow(_ session: ContentSessionManager.ContentSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.category.icon)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#7c6af7"))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(session.assetCount)/\(session.targetAssetCount) assets")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(session.platform.rawValue)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#7c6af7").opacity(0.7))
                }
            }
            Spacer()
            // Progress bar mini
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 40, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "#7c6af7"))
                    .frame(width: max(4, 40 * session.progressPercent), height: 4)
            }
            Button(action: { manager.setActive(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(hex: "#7c6af7").opacity(0.06))
    }

    func sessionRow(_ session: ContentSessionManager.ContentSession) -> some View {
        let isActive = manager.activeSession?.id == session.id
        return Button(action: { manager.setActive(session) }) {
            HStack(spacing: 8) {
                Image(systemName: session.category.icon)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? Color(hex: "#7c6af7") : .secondary)
                    .frame(width: 16)
                Text(session.title)
                    .font(.system(size: 11))
                    .foregroundColor(isActive ? .white : .secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(session.assetCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(isActive ? Color(hex: "#7c6af7").opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    var createSheet: some View {
        VStack(spacing: 20) {
            Text("Nueva sesión de contenido")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("Título del set").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Ej: Beach Editorial Marzo 2025", text: $newTitle)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Categoría").font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("", selection: $newCategory) {
                        ForEach(ContentSessionManager.ContentSession.SessionCategory.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Plataforma").font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("", selection: $newPlatform) {
                        ForEach(ContentSessionManager.ContentSession.TargetPlatform.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
            }

            HStack {
                Button("Cancelar") { showCreateSheet = false }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Crear sesión") {
                    if !newTitle.isEmpty {
                        let s = manager.create(title: newTitle, category: newCategory, platform: newPlatform)
                        manager.setActive(s)
                        showCreateSheet = false
                        newTitle = ""
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7"))
                .foregroundColor(.white).cornerRadius(6)
                .disabled(newTitle.isEmpty)
            }
        }
        .padding(24).frame(width: 360)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - SessionDashboardView

struct SessionDashboardView: View {

    @StateObject private var manager = ContentSessionManager.shared
    @State private var selectedSession: ContentSessionManager.ContentSession? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Sesiones de contenido")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { manager.refreshAllStats() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            if manager.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.1))
                    Text("Sin sesiones creadas")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(manager.sessions) { session in
                            SessionCard(session: session, isSelected: selectedSession?.id == session.id)
                                .onTapGesture { selectedSession = session }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

struct SessionCard: View {
    let session: ContentSessionManager.ContentSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.category.icon)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Image(systemName: session.platform.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(session.platform.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            // Progress
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: .infinity * session.progressPercent, height: 6)
                }
                Text("\(session.assetCount)/\(session.targetAssetCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                statPill("✓ \(session.approvedCount)", color: "#34d399")
                statPill("★ \(String(format: "%.1f", session.averageRating))", color: "#fbbf24")
                statPill("\(Int(session.approvalRate * 100))%", color: "#7c6af7")
                Spacer()
                if !session.isActive {
                    Text("Cerrada")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(4)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(hex: "#7c6af7").opacity(0.12) : Color.white.opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color(hex: "#7c6af7").opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1))
    }

    func statPill(_ text: String, color: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color(hex: color))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color(hex: color).opacity(0.1))
            .cornerRadius(4)
    }
}
