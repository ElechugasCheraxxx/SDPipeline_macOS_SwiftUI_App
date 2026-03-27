import SwiftUI

// ══════════════════════════════════════════════════════
//  DSColors.swift — Design System · Tokens · Colors
//  Fuente de verdad de colores. Nadie define colores fuera de aquí.
// ══════════════════════════════════════════════════════

public enum DSColors {

    // ── Brand ─────────────────────────────────────────
    public static let brandPrimary   = Color(red: 1.0, green: 0.0, blue: 0.87)   // Magenta
    public static let brandSecondary = Color(red: 0.9, green: 0.0, blue: 0.75)   // Magenta oscuro

    // ── Background ────────────────────────────────────
    public static let backgroundBase    = Color.black
    public static let backgroundSurface = Color(white: 0.04)   // Header
    public static let backgroundMuted   = Color(white: 0.07)   // Status bar

    // ── Text ──────────────────────────────────────────
    public static let textPrimary   = Color.white
    public static let textSecondary = Color(white: 0.6)
    public static let textAccent    = brandPrimary

    // ── Border ────────────────────────────────────────
    public static let borderDefault = brandPrimary.opacity(0.6)
    public static let borderSubtle  = brandPrimary.opacity(0.4)
    public static let borderDivider = Color(white: 0.2)

    // ── State ─────────────────────────────────────────
    public static let stateHover   = Color(red: 1.0, green: 0.0, blue: 0.95)
    public static let statePressed = brandPrimary.opacity(0.7)
    public static let stateGlow    = brandPrimary.opacity(0.7)
}
