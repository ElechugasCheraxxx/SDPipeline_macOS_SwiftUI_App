import SwiftUI
import AppKit

// MARK: - MissingSheets.swift
//
// Sheets faltantes referenciados en ContentView pero no definidos en ningún archivo.
// Ambos son wrappers delgados sobre las Views completas que ya existen en sus engines.
//
//   NewSessionSheet      → wraps lógica de ContentSessionManager.create()
//   ProjectPickerSheet   → wraps ProjectPickerView (ProjectManager.swift:382)

// MARK: - NewSessionSheet

struct NewSessionSheet: View {

    typealias Category = ContentSessionManager.ContentSession.SessionCategory
    typealias Platform = ContentSessionManager.ContentSession.TargetPlatform

    /// Callback: devuelve el title y category elegidos al ContentView
    var onConfirm: (String, Category) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title:    String   = ""
    @State private var category: Category = .editorial
    @State private var platform: Platform = .onlyfans
    @State private var titleError: Bool   = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                Text("Nueva Sesión de Contenido")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            // ── Form ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 18) {

                // Title
                formRow(label: "Nombre de la sesión") {
                    TextField("Ej: Set playa verano, Editorial urbana…", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.white.opacity(titleError ? 0.0 : 0.06))
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(titleError
                                        ? Color(hex: "#ef4444")
                                        : Color.white.opacity(0.1),
                                        lineWidth: 1)
                        )
                        .onSubmit { confirmIfValid() }
                }

                if titleError {
                    Text("El nombre no puede estar vacío")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#ef4444"))
                        .padding(.top, -12)
                }

                // Category
                formRow(label: "Categoría") {
                    HStack(spacing: 6) {
                        ForEach(Category.allCases, id: \.self) { cat in
                            categoryChip(cat)
                        }
                    }
                }

                // Platform
                formRow(label: "Plataforma destino") {
                    HStack(spacing: 6) {
                        ForEach(Platform.allCases, id: \.self) { pl in
                            platformChip(pl)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)

            Divider().background(Color.white.opacity(0.07))

            // ── Actions ─────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(7)

                Button(action: confirmIfValid) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 12))
                        Text("Crear sesión").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(hex: "#7c6af7"))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color.white.opacity(0.02))
        }
        .frame(width: 500)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }

    // MARK: - Subviews

    func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.0)
            content()
        }
    }

    func categoryChip(_ cat: Category) -> some View {
        let isSelected = category == cat
        return Button(action: { category = cat }) {
            HStack(spacing: 4) {
                Image(systemName: cat.icon).font(.system(size: 10))
                Text(cat.rawValue).font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(isSelected ? Color(hex: "#7c6af7") : Color.white.opacity(0.06))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    func platformChip(_ pl: Platform) -> some View {
        let isSelected = platform == pl
        return Button(action: { platform = pl }) {
            HStack(spacing: 4) {
                Image(systemName: pl.icon).font(.system(size: 10))
                Text(pl.rawValue).font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(isSelected ? Color(hex: "#3de3c0").opacity(0.8) : Color.white.opacity(0.06))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    func confirmIfValid() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleError = true; return }
        titleError = false
        onConfirm(trimmed, category)
    }
}

// MARK: - ProjectPickerSheet

/// Sheet wrapper delgado sobre ProjectPickerView.
/// ProjectPickerView (590 líneas) ya contiene toda la lógica de creación,
/// activación y listado de proyectos. Este struct solo lo envuelve en sheet.

struct ProjectPickerSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Close affordance
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14).padding(.top, 12)
            }

            ProjectPickerView()
                .frame(minHeight: 400)

            // Done button
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color(hex: "#7c6af7"))
                    .cornerRadius(7)
                    .padding(.trailing, 16).padding(.bottom, 14)
            }
        }
        .frame(width: 480)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }
}
