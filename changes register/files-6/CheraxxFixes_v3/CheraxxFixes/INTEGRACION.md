# Cheraxx KeyMapper — Guía de Integración
## CheraxxFixes v3 (sesión final de correcciones)

---

## Qué hay en este paquete

Este ZIP contiene **todos los archivos corregidos** del proyecto Cheraxx KeyMapper,
listos para sustituir a sus equivalentes en Xcode.

---

## Sesión 3 — 6 errores de compilación + 1 bug de runtime + validación

| # | Archivo | Tipo | Descripción |
|---|---|---|---|
| 1 | `Commands/CheraxxCommands.swift` | Error compilación | `Notification.Name` redeclarada — eliminado bloque duplicado (ya está en AppNotifications.swift) |
| 2 | `Models/ActionType.swift` | Error compilación | `SkillSlot` sin `targetX`/`targetY` — añadidos con valor por defecto `50.0` |
| 3 | `Core/ActionExecutors.swift` | Error compilación | `ScriptExecutor` usaba `step.action` (no existe) — reescrito para `step.type` / `step.x` / `step.y` |
| 4 | `Core/KeyMapper.swift` + `CheraxxApp.swift` | Bug runtime | Dos `WindowTracker` distintos — `windowTracker` en KeyMapper ahora es `var` e inyectado desde `AppSetupModifier` |
| 5 | `UI/MenuBarView.swift` + `UI/PermissionsView.swift` | Error compilación | `CheraxxTheme.fontHeading` no existe — corregido a `.fontHeadline` |
| 6 | `Models/ActionType.swift` | Error compilación | `MappingProfile.bindings` sin valor por defecto — añadido `= []` |
| 7 | `Core/ActionExecutors.swift` | Validación runtime | `ScriptExecutor` no validaba `x`/`y` nulos — pasos sin coordenadas se omiten con `log.warning` |

---

## Archivos nuevos en esta sesión

| Archivo | Motivo |
|---|---|
| `Models/ActionType.swift` | No estaba en CheraxxFixes anterior; contiene todos los modelos: `ActionType`, `ActionParams`, `SkillSlot`, `MacroStep`, `KeyBinding`, `MappingProfile` |
| `Overlay/OverlayWindowController.swift` | **No existía en el código fuente original.** Escrito desde cero con los dos bugs del audit resueltos: (a) `updateProfile()` apilaba `hostingView` sin eliminar anterior → memory leak + corrupción visual; (b) click-through correcto en zonas sin widgets |

---

## Estructura del paquete

```
CheraxxFixes/
├── INTEGRACION.md
├── CheraxxApp.swift                      ← reemplaza CheraxxApp.swift
├── Cheraxx KeyMapper.entitlements        ← reemplaza el .entitlements existente
│
├── Commands/
│   └── CheraxxCommands.swift             ← reemplaza existente
│
├── Core/
│   ├── ActionExecutors.swift             ← reemplaza existente
│   ├── EventTapManager.swift             ← reemplaza existente
│   ├── KeyMapper.swift                   ← reemplaza existente
│   ├── MirroringCaptureManager.swift     ← reemplaza existente
│   ├── MouseSimulator.swift              ← reemplaza existente
│   ├── OverlayManager.swift              ← reemplaza existente
│   └── WindowTracker.swift              ← reemplaza existente
│
├── Models/
│   └── ActionType.swift                  ← reemplaza existente (NUEVO en CheraxxFixes v3)
│
├── Overlay/
│   ├── OverlayView.swift                 ← reemplaza existente
│   └── OverlayWindowController.swift     ← NUEVO (no existía en el código fuente)
│
├── Persistence/
│   └── ProfileStore.swift               ← reemplaza existente
│
├── UI/
│   ├── ContentView.swift                 ← reemplaza existente
│   ├── MappingCanvasView.swift           ← reemplaza existente
│   ├── MenuBarView.swift                 ← reemplaza existente
│   └── PermissionsView.swift            ← reemplaza existente
│
└── Utils/
    └── AppNotifications.swift            ← reemplaza existente
```

---

## Cómo integrar en Xcode

### Opción A — Finder (recomendada)

1. Descomprime el ZIP
2. Copia los archivos a las carpetas equivalentes de tu proyecto, reemplazando los existentes
3. Xcode 15/16 con `fileSystemSynchronizedGroups` detecta los cambios automáticamente

### Para `OverlayWindowController.swift` (archivo nuevo)

- Copia a `<proyecto>/Overlay/OverlayWindowController.swift`
- En Xcode 15/16: se añade al build target automáticamente
- En Xcode 14 o anterior: botón derecho en el grupo Overlay → "Add Files to 'CheraxxKeyMapper'"

### Para `Models/ActionType.swift` (reemplaza el existente)

- Copia a `<proyecto>/Models/ActionType.swift` reemplazando el anterior

---

## Dependencias entre archivos nuevos (sesión 3)

```
CheraxxApp.swift
  └── inyecta el windowTracker compartido → keyMapper.windowTracker = windowTracker

Models/ActionType.swift
  └── SkillSlot.targetX / targetY        → requeridos por SkillsPadExecutor
  └── MappingProfile.bindings = []       → requerido por ContentView

Core/ActionExecutors.swift (ScriptExecutor)
  └── step.type  → MacroStep.StepType (.tap / .swipe / .wait)
  └── step.x, step.y → Double? (validados antes de usar)
  └── step.delayMs → se aplica ANTES del paso

Overlay/OverlayWindowController.swift
  └── OverlayPanel (NSPanel no-activante)
  └── OverlayHitView (click-through en zonas vacías)
  └── NSHostingController<OverlayView> (reemplazado limpiamente en updateProfile)
```

---

## Estado esperado tras integración

- ✅ **0 errores de compilación** — los 6 de sesión 3 resueltos
- ✅ **WindowTracker compartido** — KeyMapper y OverlayManager observan el mismo estado
- ✅ **OverlayWindowController sin fugas** — hostingView anterior eliminado antes de reemplazar
- ✅ **ScriptExecutor robusto** — coordenadas nulas manejadas con `log.warning`, no crash
- ⚠️ **Assets.xcassets**: AppIcon sin imágenes reales → warning de Xcode, no error
- ⚠️ **Tests**: no incluidos, requieren trabajo manual
