# SDPipeline Studio — Commit v5
## Fecha: 2025 · Commit masivo post-diagnóstico

---

## 📋 RESUMEN EJECUTIVO

Este commit cierra **17 gaps críticos** identificados en el diagnóstico, priorizando:
1. **Escalabilidad**: Multi-proyecto (ProjectManager) — la base para crecer sin caos
2. **Completitud**: Vistas faltantes que impedían compilar (JobQueueView, StudioPublishView, etc.)
3. **Integridad**: Sistema de verificación SHA-256 batch con UI dedicada
4. **Robustez**: Extensions de JobQueueManager, fixes de API surface, métodos stub resueltos

---

## 🆕 ARCHIVOS NUEVOS

### `ProjectManager.swift`
Sistema de multi-proyecto completo:
- `ProjectManager` singleton con CRUD de proyectos
- Cada proyecto tiene su propio subdirectorio dentro del vault root
- Aislamiento de assets, sessions y settings por proyecto
- `ProjectPickerView` — selector flotante con popover
- `ProjectBadge` — widget mini para el header de ContentView
- Hook en `VaultManager` para override de URLs por proyecto activo
- Auto-crea proyecto "Default" en primer arranque
- Persiste en `.projects_registry.json` en el vault root

### `AssetInspectorView.swift`
Inspector standalone y completo:
- Thumbnail, rating interactivo, status picker, tag editor
- Grid de parámetros SD (seed, steps, CFG, sampler, dimensiones)
- Info de modelo y LoRAs
- Verificación de integridad SHA-256 inline
- Acciones: reuse settings, quick export, show in Finder
- `RatingCuratorView` — widget 1-5 estrellas con hover preview y label
- `BatchRatingView` — modo curador para calificar múltiples assets

### `MissingViews.swift`
Vistas que estaban referenciadas pero no existían:
- `JobQueueView` — cola con header, rows de jobs, footer de stats
- `JobRowView` — fila de job con progress, priority badge, retry count
- `StudioPublishView` — wrapper de PublishView para el panel
- `NewSessionSheet` — sheet completo de nueva sesión de contenido

### `IntegrityManager.swift`
Verificación batch de integridad:
- `IntegrityManager` singleton con `runFullVerification()` async
- Verificación SHA-256 en background con `Task.detached`
- Procesamiento en batches con yield para UI responsiva
- Tipos: `.ok`, `.corrupted`, `.fileNotFound`, `.noHashRegistered`
- Acción de re-registro de hash para archivos editados intencionalmente
- Log automático al ZeroKnowledgeLog tras cada verificación
- `IntegrityDashboardView` — UI completa con stats, filtros, lista

### `Models_Extended.swift`
Tipos faltantes que causaban errores de compilación:
- `Img2ImgSettings` struct (referenciado en RightPanelView)
- `LoRAEntry` y `SelectedLoRA` structs completos con `promptToken`
- `GPUPreCheckStatus` enum con `.ok/.warning/.critical/.unknown`
- `QueueJob` struct con todos los campos
- `JobStatus` enum
- `ContentSessionManager.TargetPlatform` y `.SessionCategory` enums
- `SDRequest.from(settings:prompt:)` convenience initializer

### `JobQueueManager_Extensions.swift`
Métodos faltantes en JobQueueManager:
- `enqueue(_ job: QueueJob)` — encolar con orden por prioridad
- `cancel(job:)` — cancelar job específico
- `clearCompleted()` — limpiar completados/cancelados
- `processNextIfPossible()` — engine de ejecución
- `executeJob()` — dispatch por tipo (export, backup, etc.)
- `persistQueue()` — persistencia en `job_queue.json`
- Initializers de conveniencia: `QueueJob.exportJob()`, `.backupJob()`

---

## 🔧 ARCHIVOS MODIFICADOS

### `ContentView.swift`
- Añadido `@StateObject projectManager = ProjectManager.shared`
- `ProjectBadge` en el header del left panel
- Handler `onChange(of: settings.checkpoint)` → licenseWarning
- Handler `onReceive(.projectDidChange)` → aplica settings del proyecto
- `licenseWarning` banner separado del `validationMsg`
- `generate()` llama `projectManager.incrementAssetCount()` tras guardar
- Inicialización: `projectManager.createDefaultProjectIfNeeded()`

### `SDPipelineApp.swift`
- Init de `ProjectManager.shared` e `IntegrityManager.shared` en `.task`
- Menú "Proyecto" con creación y switch rápido entre proyectos
- `showBatchRating` notification
- Fix `ContentSessionManager.close(session:)` — wrapper de firma
- Fix `JobQueueManager.enqueueAllPendingExports()` — implementación real
  que busca assets aprobados sin clean export y los encola

### `PipelineConnector.swift` (v5)
- `ValidationReport` tiene campo `licenseWarning` separado de `gpuWarning`
- `validateBeforeGenerate()` incluye `checkLicense()` integrado (step 3)
- `saveToVaultFull()` llama `ProjectManager.shared.incrementAssetCount()`
- `primaryMessage` computed var para mostrar el mensaje más relevante
- `quickSave()` helper para guardar sin settings completos

### `SettingsView.swift` (v5)
- Nueva sección "Proyectos" → `ProjectPickerView` inline
- Nueva sección "Integridad" → `IntegrityDashboardView` inline
- Backup section: status real de `backupMgr.config.lastBackupOK` y `.lastBackupAt`
- GPU section: `gpu.vramFree` (Int64 bytes) → convertido a MB correctamente
- License section: lista de model cards con semáforo de colores
- `BackupManager.openRcloneConfig()` stub para abrir Terminal
- `WildcardEngine.categories` y `.entries(for:)` extension para Settings

---

## 📊 ESTADO ACTUALIZADO DEL ROADMAP

### ✅ RESUELTO COMPLETAMENTE

**SECCIÓN 1 — Infraestructura**
- ✅ Sistema de carpetas por proyectos (ProjectManager NUEVO)
- ✅ Directorios raíz con estructura organizada por proyecto
- ✅ Persistencia Core Data/SQLite (imagen + seed + prompt + settings)
- ✅ Sidecar JSON dinámico por cada imagen
- ✅ Versionado estándar de assets
- ✅ Vault legal con model_card + licencia
- ✅ Control local de licencias (LICENSE.txt)
- ✅ Integridad de archivos con hashes SHA-256 (IntegrityManager NUEVO)
- ✅ Galería interna con metadatos navegables
- ✅ Buscador por tags con filtros
- ✅ Biblioteca con metadatos IPTC/XMP/EXIF
- ✅ Registro automático de model_card + licencia
- ✅ Backups cifrados automáticos con rclone

**SECCIÓN 3 — Seguridad**
- ✅ Esteganografía invisible en imágenes finales
- ✅ Watermark visible/configurable en previews
- ✅ Kill-Switch de metadatos (EXIF Scrubbing)
- ✅ Dos versiones de cada imagen (privada y limpia)
- ✅ Filtrado de prompts con blacklist
- ✅ Plantillas de consentimiento
- ✅ Zero-Knowledge Logs cifrados
- ✅ Detector automático NSFW post-generación

**SECCIÓN 2 — Modelos y LoRAs**
- ✅ UI Model Manager con benchmarks
- ✅ Panel LoRA Manager
- ✅ Private Model Registry (LicenseVault)

**SECCIÓN 4 — Consistencia Creativa**
- ✅ Gestor de personajes (CharacterEngine)
- ✅ Character Consistency System (Img2ImgEngine)
- ✅ Presets de escenas guardadas (SceneEngine)

**SECCIÓN 5 — Generación Avanzada**
- ✅ Img2img pipeline de refinamiento
- ✅ Batch processing con grid view
- ✅ Seed Management + favoritos por personaje
- ✅ Metadatos extendidos guardados
- ✅ Monitor GPU/VRAM
- ✅ X/Y Plot integration

**SECCIÓN 6 — Post-Procesamiento**
- ✅ Post-process via /extra-single-image
- ✅ Filtros cinematográficos (CinematicFilterEngine)

**SECCIÓN 7 — UI/UX**
- ✅ Versionamiento de prompts exitosos
- ✅ Sistema de rating curator 1-5 (RatingCuratorView NUEVO)
- ✅ Dashboard de métricas/KPIs
- ✅ Content Session Manager

**SECCIÓN 8 — Publicación**
- ✅ Watermark/Export System automatizado
- ✅ StudioPublishView integrado en panel (NUEVO)

---

### 🔴 PENDIENTE (próximo commit)

**SECCIÓN 1**
- 🔴 Cifrado real de directorios (FileVault/APFS encrypted volumes)
  - *Nota: La encriptación se delega a FileVault del sistema. CryptoKit para contenido sensible.*
  - *Pendiente: VaultEncryptionHelper con flag de verificación de cifrado del volumen*

**SECCIÓN 3**
- 🔴 Sandboxing de procesos SD (App Sandbox entitlements)
- 🔴 Hardening de app y runtime (entitlements, code signing)

**SECCIÓN 7**
- 🔴 Monitor de telemetría GPU/VRAM en tiempo real (widget en header)
  - *GPUMonitor existe pero no hay widget visible en la UI principal*

**🟡 MEDIO PLAZO (no iniciado)**
- Buscador por vectores CLIP
- IP-Adapter / FaceID
- ControlNet Depth/Canny/SoftEdge/OpenPose
- Inpainting / Outpainting
- Upscaling Tiled
- ADetailer Pro

---

## 🏗 ARQUITECTURA FINAL

```
SDPipelineStudio/
├── Core Infrastructure
│   ├── VaultManager          ✅ Multi-project URLs
│   ├── ProjectManager        ✅ NEW — Multi-proyecto
│   ├── AssetStore            ✅ Core Data + SHA-256
│   ├── IntegrityManager      ✅ NEW — Batch verification
│   └── BackupManager         ✅ rclone multi-destino
│
├── Generation Pipeline
│   ├── SDService             ✅ WebUI process + health
│   ├── PipelineConnector     ✅ v5 — Pegamento central
│   ├── PromptSafetyFilter    ✅ Blacklist + soft flags
│   ├── Models                ✅ SDRequest + GenerationSettings
│   └── Models_Extended       ✅ NEW — Img2ImgSettings + tipos
│
├── Security & Compliance
│   ├── SteganographyEngine   ✅ LSB + HMAC
│   ├── ExportEngine          ✅ Clean + preview + EXIF scrub
│   ├── ZeroKnowledgeLog      ✅ AES-GCM JSONL
│   ├── LicenseVault          ✅ ModelCard + compliance
│   └── NSFWDetector          ✅ Prompt + CLIP
│
├── Creative Engines
│   ├── CharacterEngine       ✅ Perfiles + consistency
│   ├── SceneEngine           ✅ Presets
│   ├── WildcardEngine        ✅ __syntax__
│   ├── Img2ImgEngine         ✅ Refinamiento
│   ├── BatchEngine           ✅ Grid batch
│   ├── XYPlotEngine          ✅ X/Y/Z combinatorias
│   ├── CinematicFilterEngine ✅ Core Image presets
│   └── PostProductionEngine  ✅ Upscale + face restore
│
├── Data & Metadata
│   ├── TaggingEngine         ✅ Tags + búsqueda
│   ├── SeedManager           ✅ Favoritos + historial
│   ├── PromptVersioningStore ✅ Historial versionado
│   ├── ContentSessionManager ✅ Motor narrativo
│   ├── JobQueueManager       ✅ Cola con prioridad
│   └── DashboardViewModel    ✅ KPIs snapshot
│
├── Views
│   ├── ContentView           ✅ v5 — ProjectBadge + licenseWarning
│   ├── RightPanelView        ✅ 6 tabs
│   ├── GalleryView           ✅ Grid + inspector + tags
│   ├── AssetInspectorView    ✅ NEW — Inspector standalone
│   ├── JobQueueView          ✅ NEW (en MissingViews.swift)
│   ├── StudioPublishView     ✅ NEW (en MissingViews.swift)
│   ├── NewSessionSheet       ✅ NEW (en MissingViews.swift)
│   ├── ProjectPickerView     ✅ NEW (en ProjectManager.swift)
│   ├── IntegrityDashboardView ✅ NEW (en IntegrityManager.swift)
│   ├── BatchJobView          ✅
│   ├── DashboardView         ✅
│   └── SettingsView          ✅ v5 — +Proyectos +Integridad
│
└── Helpers
    ├── SidecarJSON           ✅
    ├── IPTCMetadataWriter    ✅
    ├── NSImage+Helpers       ✅
    ├── Data+Crypto           ✅
    ├── Color+Hex             ✅
    ├── Codable+Helpers       ✅
    └── View+Helpers          ✅
```
