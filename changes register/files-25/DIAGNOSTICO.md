# SDPipeline Studio — Diagnóstico Completo
## Estado al commit actual

---

## ✅ RESUELTO (código funcional y completo)

### SECCIÓN 1 — Infraestructura
- ✅ **VaultManager** — Estructura de directorios, security-scoped bookmarks, first-run sheet
- ✅ **AssetStore** — Core Data stack programático, saveAsset async, SHA-256, thumbnails
- ✅ **SidecarJSON** — Sidecar completo por cada imagen con linaje de modelo
- ✅ **Versionado de assets** — baseName + version en Core Data y disco
- ✅ **LicenseVault** — ModelCard, LICENSE.txt snapshots, compliance check, plantillas consentimiento
- ✅ **BackupManager** — rclone multi-destino, scheduler, manifiestos SHA-256 (completo)

### SECCIÓN 3 — Seguridad
- ✅ **SteganographyEngine** — LSB embedding, HMAC payload, ArtistID en Keychain
- ✅ **ExportEngine** — Dos versiones (clean + preview), EXIF scrub, PNG chunk removal
- ✅ **WatermarkConfig** — Posición, opacidad, texto configurable
- ✅ **PromptSafetyFilter** — Blacklist por categorías, soft flags, JSON schema validation
- ✅ **ZeroKnowledgeLog** — AES-GCM, Keychain key, JSONL cifrado, loadAll/rotate
- ✅ **IPTCMetadataWriter** — IPTC/XMP/EXIF embedding en clean export

### SECCIÓN 2 — Modelos y LoRAs
- ✅ **ModelManager** — Fetch desde A1111 `/sdapi/v1/sd-models`, switch checkpoint
- ✅ **LoRAManager** — Fetch `/sdapi/v1/loras`, SelectedLoRA con weight
- ✅ **NSFWDetector** — Prompt scoring + CLIP via A1111, policy configurable, log JSONL

### SECCIÓN 4 — Consistencia Creativa
- ✅ **CharacterEngine** — Perfiles JSON, pinSeed, img2img base, persistencia
- ✅ **SceneEngine** — Presets de escenas, persistencia JSON
- ✅ **Img2ImgEngine** — Pipeline refine con denoise configurable

### SECCIÓN 5 — Generación Avanzada
- ✅ **SDService** — WebUI process management, launch/stop, health poll
- ✅ **BatchEngine** — Grid batch processing
- ✅ **SeedManager** — Favoritos, historial 500, rating, linkToCharacter
- ✅ **GPUMonitor** — Device detection, VRAM polling, preCheckStatus
- ✅ **XYPlotEngine** — X/Y/Z combinatorias, execution engine
- ✅ **WildcardEngine** — Wildcards dinámicos con __syntax__

### SECCIÓN 6 — Post-Procesamiento
- ✅ **PostProductionEngine** — Upscale + face restore via A1111 /extra-single-image
- ✅ **CinematicFilterEngine** — Filtros Core Image, presets persistidos

### SECCIÓN 7 — UI/UX
- ✅ **PromptVersioningStore** — Historial versionado, búsqueda, rating
- ✅ **TaggingEngine** — Tag index, auto-suggest, TagFilterBar, FlowLayout
- ✅ **DashboardView/ViewModel** — KPIs, snapshot, métricas generales
- ✅ **GalleryView** — Grid, inspector, bulk, filtros completos
- ✅ **ContentSessionManager** — Motor narrativo, sesiones, stats
- ✅ **JobQueueManager** — Cola prioridad, retry, workers

### SECCIÓN 8 — Publicación
- ✅ **PublishEngine** — Export presets (OnlyFans/Instagram/Twitter), watermark, records
- ✅ **PublishView** — UI completa de publicación

---

## 🔴 FALTANTE / INCOMPLETO (prioridad para este commit)

### CRÍTICO — Sin implementar real
1. **ProjectManager** — No existe. VaultManager solo gestiona UN vault flat. Falta sistema de proyectos múltiples con carpetas aisladas, switch de proyecto activo, metadata por proyecto.
2. **VaultEncryption** — VaultManager no cifra directorios. Solo guarda en disco plano. Falta integración con FileVault/APFS encryption o cifrado de carpetas con CryptoKit.
3. **IntegrityDashboard** — AssetStore.verifyIntegrity() existe pero no hay UI ni job automático de verificación batch.
4. **ContentView — Validación en UI** — PipelineConnector.validateBeforeGenerate() existe pero el bloqueo en ContentView no muestra el gpuWarning correctamente ni integra el licenseCheck.
5. **SettingsView — Secciones incompletas** — backup section y gpu section tienen código pero falta conectar correctamente los bindings a BackupManager y GPUMonitor.
6. **RatingCuratorView** — Referenciada en GalleryView pero no definida como tipo standalone. Está inline y no puede reutilizarse desde otros contextos.
7. **VaultSetupSheet** — Existe en VaultManager.swift pero falta campo de nombre de proyecto y descripción.
8. **AssetInspectorView** — Referenciada en GalleryView pero no está en los archivos subidos (posiblemente falta o está inline incompleto).
9. **NewSessionSheet** — Referenciada en ContentView pero no aparece en archivos (falta o está inline).
10. **StudioPublishView** — Referenciada en RightPanelView (.publish tab) pero es diferente a PublishView — no existe como tipo standalone con ese nombre exacto.
11. **JobQueueView** — Referenciada en RightPanelView pero no aparece como tipo en los archivos subidos.
12. **ModelBuilderSheet** — Referenciada en ContentView pero Modelbuilderview.swift puede tener nombre distinto.
13. **XYPlotView** — Referenciada en ContentView pero puede estar incompleta en XYPlotEngine.swift.

### IMPORTANTE — Stubs/Parciales
14. **Img2ImgSettings** — Referenciada en RightPanelView como `Img2ImgSettings()` pero puede no estar definida en los archivos.
15. **VaultManager.licenciasURL** — Existe, pero falta cifrado del subdirectorio.
16. **BackupManager.enqueueAllPendingExports()** — Llamado en SDPipelineApp pero puede estar como stub.
17. **ContentSessionManager.close()** — Llamado en SDPipelineApp pero puede ser stub.
18. **SteganographyEngine** — No es `@MainActor` pero se llama desde Task.detached correctamente. OK.

---

## 📋 PLAN DEL COMMIT — Archivos a crear/modificar

### Nuevos archivos (no existen en el proyecto)
1. `ProjectManager.swift` — Multi-proyecto con aislamiento de vault
2. `AssetInspectorView.swift` — Inspector standalone reutilizable
3. `RatingCuratorView.swift` — Rating widget standalone
4. `JobQueueView.swift` — View de cola de jobs
5. `StudioPublishView.swift` — Wrapper de PublishView para el panel
6. `NewSessionSheet.swift` — Sheet de nueva sesión
7. `IntegrityManager.swift` — Batch integrity check con UI
8. `VaultEncryptionHelper.swift` — Helper de cifrado/APFS

### Archivos a mejorar (correcciones y completar)
9. `ContentView.swift` — Fix validación GPU warning + licenseCheck + conectar ProjectManager
10. `PipelineConnector.swift` — Agregar checkLicense integrado en validateBeforeGenerate
11. `Models.swift` — Agregar Img2ImgSettings struct faltante
12. `SDPipelineApp.swift` — Fix enqueueAllPendingExports + close session + ProjectManager init
13. `VaultManager.swift` — Agregar soporte multi-proyecto
14. `SettingsView.swift` — Completar backup section + GPU section + IntegrityView
15. `GalleryView.swift` — Fix AssetInspectorView reference + RatingCuratorView
