# Cheraxx KeyMapper for iOS Mirroring
### Dark Gaming × macOS 26 Tahoe · Swift 6 · SwiftUI

---

## Estructura del Proyecto en Xcode

```
CheraxxKeyMapper/
├── CheraxxApp.swift
├── AppDelegate.swift
│
├── Core/
│   ├── WindowTracker.swift       ← Busca la ventana de iPhone Mirroring (AXUIElement)
│   ├── EventTapManager.swift     ← Intercepta teclado globalmente (CGEventTap)
│   ├── MouseSimulator.swift      ← Simula clicks/swipes (CGEvent)
│   └── KeyMapper.swift           ← Conecta todo: tecla → acción → simulación
│
├── Models/
│   └── ActionType.swift          ← ActionType enum + ActionParams + KeyBinding + MappingProfile
│
├── Overlay/
│   ├── OverlayWindowController.swift  ← NSWindow transparente sobre iPhone Mirroring
│   └── OverlayView.swift              ← HUD SwiftUI (widgets de controles)
│
├── UI/
│   ├── ContentView.swift              ← NavigationSplitView principal
│   ├── SidebarView.swift              ← Lista de perfiles
│   ├── MappingCanvasView.swift        ← Canvas drag & drop + click para añadir
│   ├── BindingInspectorView.swift     ← Panel derecho de detalles
│   └── PermissionsView.swift          ← SettingsView + MenuBarView + Commands
│
├── Persistence/
│   ├── ProfileStore.swift             ← CRUD + import/export
│   └── BlueStacksImporter.swift       ← Convierte JSON de BlueStacks → MappingProfile
│
├── Utils/
│   └── KeyCodeHelper.swift            ← CGKeyCode → String
│
└── Resources/
    └── CheraxxTheme.swift             ← Design tokens, colores, tipografía, modificadores
```

---

## Configuración en Xcode

### 1. Nuevo proyecto
- File → New → Project → **macOS App**
- Product Name: `CheraxxKeyMapper`
- Interface: **SwiftUI**
- Language: **Swift**
- Bundle ID: `com.cheraxx.keymapper`

### 2. Deployment Target
- **macOS 15.0** (mínimo requerido para iPhone Mirroring)

### 3. Info.plist — Permisos requeridos
Añade estas entradas en `Info.plist`:

```xml
<!-- Descripción de uso de Accesibilidad -->
<key>NSAccessibilityUsageDescription</key>
<string>Cheraxx necesita acceso de Accesibilidad para interceptar el teclado y simular eventos de mouse sobre iPhone Mirroring.</string>

<!-- Tipo de archivo nativo .immap -->
<key>UTExportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>com.cheraxx.immap</string>
        <key>UTTypeDescription</key>
        <string>Cheraxx KeyMapper Profile</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.json</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>immap</string>
            </array>
        </dict>
    </dict>
</array>
```

### 4. Entitlements
Crea `CheraxxKeyMapper.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Required for CGEventTap -->
    <key>com.apple.security.temporary-exception.accessibility</key>
    <true/>
    <!-- App Sandbox: OFF (required for CGEventTap + Accessibility) -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <!-- Allow writing to Application Support -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

> ⚠️ **App Sandbox debe estar DESACTIVADO** para que CGEventTap funcione.
> Esto significa que la app no puede publicarse en la Mac App Store,
> pero sí distribuirse directamente (notarización).

### 5. Signing
- Signing & Capabilities → **Automatically manage signing**
- Team: tu Apple Developer account

---

## Paleta de Colores (macOS 26 Tahoe Gaming)

| Token | Hex | Uso |
|---|---|---|
| `accentCyan` | `#00D4FF` | Acento principal |
| `accentOrange` | `#FF6B35` | Teclas / advertencias |
| `accentGreen` | `#39FF85` | Estado activo / conectado |
| `accentRed` | `#FF3B5C` | Peligro / eliminar |
| `backgroundPrimary` | `#090D18` | Fondo principal |
| `backgroundSecondary` | `#0F1525` | Sidebar / paneles |
| `backgroundElevated` | `#151C30` | Cards / inputs |

---

## Formatos de Archivo Soportados

| Formato | Extensión | Operación |
|---|---|---|
| Nativo Cheraxx | `.immap` | Leer + Escribir |
| BlueStacks Config | `.json` | Solo importar → convierte a `.immap` |

---

## Permisos del Sistema Requeridos

1. **Accesibilidad** — Para `CGEventTap` (interceptar teclado) y `AXUIElement` (encontrar ventana)
2. Sin más permisos requeridos (no necesita micrófono, cámara, ni red)
