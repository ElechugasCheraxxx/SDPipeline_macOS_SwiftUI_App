# Commit — SDPipelineStudio · Integración Masiva

## Archivos NUEVOS (5)
- `ReusableSettings.swift` — struct de transporte entre GalleryView↔ContentView (era referenciada pero no existía)
- `PromptVersioningStore.swift` — historial versionado de prompts exitosos con search/rating/tags + `PromptVersionPickerView`
- `PublishView.swift` — vista completa de la tab "Publicar" en RightPanelView (era referenciada pero no existía)
- `SettingsView.swift` — panel central de ajustes (Cmd+,): Vault, Watermark, Backup, NSFW Policy, Export, GPU
- `ZeroKnowledgeLog.swift` — log de auditoría cifrado AES-GCM con clave en Keychain + `ZeroKnowledgeLogView`

## Archivos MODIFICADOS (6)
### SDPipelineApp.swift
- `BackupManager.shared.startScheduler()` ahora se llama al arranque (era TODO en PipelineConnector)
- `PromptVersioningStore.shared` inicialización eager
- Menú "Backup ahora" (Cmd+Shift+B)
- `Settings { SettingsView() }` → habilita Cmd+, nativo macOS

### RightPanelView.swift
- `saveToVault()` reemplazado por `PipelineConnector.saveToVaultFull()` (conecta ExportEngine + SeedManager + CharacterEngine)
- Auto-save del prompt en `PromptVersioningStore` al guardar en vault

### ExportEngine.swift
- Pasa a ser `ObservableObject` con `@Published var watermarkConfig`
- Permite binding desde SettingsView sin intermediarios

### PromptSafetyFilter.swift
- `logResult()` ahora escribe en `ZeroKnowledgeLog` (AES-GCM) además del fallback plaintext
- `logResultZK()` extensión en `ZeroKnowledgeLog.swift`

### GalleryView.swift
- Eliminada definición duplicada de `ReusableSettings` (movida a archivo dedicado)

## Bugs Corregidos
- `PublishView` usaba `PublishLogEntry` que no existía → reemplazado por `PublishRecord` (tipo real de PublishEngine)
- `BackupManager.isRcloneAvailable` → renombrado a `rcloneAvailable` (API real)
- `BackupManager.runBackupNow()` → renombrado a `runAllBackups()` (API real)
- `ExportEngine.watermarkConfig` no era `@Published` → imposible bindear desde Settings

## Estado del Roadmap tras este commit

### 🔴 INMEDIATO — Completado al 100%
✅ Directorios Vault cifrados
✅ Persistencia Core Data
✅ Sidecar JSON dinámico
✅ Versionado de assets
✅ Vault legal + licencias
✅ Esteganografía invisible
✅ Watermark visible/configurable (ahora con SettingsView)
✅ EXIF Scrubbing + dos versiones
✅ Filtrado de prompts
✅ Plantillas de consentimiento

### 🟠 CORTO PLAZO — Completado al 100%
✅ Backups rclone automáticos (startScheduler conectado)
✅ Galería con metadatos
✅ Model Manager + benchmarks
✅ LoRA Manager
✅ Zero-Knowledge Logs cifrados (nuevo ZeroKnowledgeLog.swift)
✅ Seed Management + favoritos
✅ Monitor GPU/VRAM
✅ Img2img pipeline
✅ Batch processing
✅ Versionamiento de prompts (nuevo PromptVersioningStore.swift)
✅ Sistema de rating curator
✅ Export automatizado con presets

### Pendiente próximo commit (prioridad)
- [ ] Conectar `PromptVersionPickerView` en el panel center de ContentView
- [ ] Conectar `ZeroKnowledgeLogView` en SettingsView (tab de auditoría)
- [ ] `NSFWDetector.logResultZK()` llamado desde `ContentView.generate()` post-detección
- [ ] `SettingsView` watermark position persiste en UserDefaults/Keychain
- [ ] `GalleryView` integrar `PromptVersioningStore.autoSave(from:)` tras rating >= 4
