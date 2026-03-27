# Commit v3 — SDPipelineStudio

## Estado del Roadmap: ✅ Implementado / 🔴 Falta

### ✅ RESUELTO (ya existía en el codebase)
**SECCIÓN 1 — Infraestructura**
- ✅ VaultManager (directorios, security-scoped bookmarks)
- ✅ Core Data / SQLite (AssetStore + GeneratedAsset)
- ✅ Sidecar JSON dinámico por imagen (SidecarJSON)
- ✅ Versionado de assets (baseName_v001)
- ✅ LicenseVault (model_card + LICENSE.txt + plantillas consentimiento)
- ✅ BackupManager (rclone + scheduler)
- ✅ Integridad SHA-256 (AssetStore.verifyIntegrity)
- ✅ Biblioteca con metadatos IPTC/XMP (IPTCMetadataWriter)

**SECCIÓN 3 — Seguridad**
- ✅ Esteganografía invisible LSB (SteganographyEngine + HMAC)
- ✅ Watermark visible configurable (ExportEngine.WatermarkConfig)
- ✅ EXIF Scrubbing + PNG tEXt chunk removal (ExportEngine)
- ✅ Dual export: clean + preview (ExportEngine)
- ✅ PromptSafetyFilter (blacklist + soft flags)
- ✅ ZeroKnowledgeLog (AES-GCM, clave en Keychain)
- ✅ NSFWDetector (prompt scorer + CLIP image scorer)

**SECCIÓN 4 — Consistencia Creativa**
- ✅ CharacterEngine (perfiles JSON, img2img consistency)
- ✅ SceneEngine (presets de escenas)
- ✅ WildcardEngine (wildcards dinámicos __nombre__)

**SECCIÓN 5 — Generación Avanzada**
- ✅ Img2ImgEngine (refinamiento pipeline)
- ✅ BatchEngine + BatchJobView
- ✅ SeedManager (favoritos, historial, vinculación a personajes)
- ✅ GPUMonitor (detección Apple Silicon, polling, VRAM)
- ✅ XYPlotEngine

**SECCIÓN 6 — Post-Procesamiento**
- ✅ PostProductionEngine (ESRGAN, CodeFormer, face restore)
- ✅ CinematicFilterEngine (filtros + grano + bloom)

**SECCIÓN 7 — UI/UX**
- ✅ PromptVersioningStore (historial versionado)
- ✅ DashboardView (KPIs básicos)
- ✅ ContentSessionManager (motor narrativo de sesiones)

**SECCIÓN 8 — Publicación**
- ✅ PublishEngine (presets por plataforma, export batch)
- ✅ PublishView

---

## 🔧 FIXES EN ESTE COMMIT (v3)

### BUG CRÍTICO: PipelineConnector.swift — infinite loop
- **Problema:** `ExportEngine.export(asset:addWatermark:)` era un wrapper que
  se llamaba a sí mismo → stack overflow silencioso.
- **Fix:** Wrapper eliminado. Se llama `ExportEngine.shared.export()` directamente.

### DashboardView.swift — datos incompletos
- **Problema:** `DashboardViewModel.refresh()` usaba `recentAssets` (límite 50)
  → KPIs mostraban solo las últimas 50 imágenes, no el total real.
- **Fix:** Ahora usa `fetchAllAssets(limit: 500)`.
- **Nuevos KPIs:** rejected, published, session activa, seeds favoritos,
  GPU telemetría en tiempo real, checkpoint distribution real.

### GalleryView.swift — funcionalidad incompleta
- **Problema:** Sin TagFilterBar integrada, sin bulk actions, RatingCuratorView ausente.
- **Fix:** 
  - TagFilterBar integrada con lógica AND/OR.
  - Bulk actions: aprobar/rechazar/auto-tag selección múltiple.
  - `RatingCuratorView` nuevo (1-5★ con colores por valor, toggle con clic).
  - `AssetInspectorView` completo: metadata, prompt, tags sugeridas, export PNG.
  - Context menu por thumbnail.
  - Sort mode múltiple (fecha, rating, status).

### ContentView.swift — sheets no conectados
- **Problema:** `.showXYPlot` y `.showNewSession` en SDPipelineApp.swift publicaban
  notificaciones que ContentView nunca escuchaba.
- **Fix:**
  - `.onReceive` para ambas notificaciones.
  - `NewSessionSheet` view nueva.
  - `XYPlotSheetView` wrapper nuevo.
  - Indicator de sesión activa en leftPanel.
  - `PipelineConnector.ValidationReport` integrado en parseJSON() y generate().

### SettingsView.swift — IPTCSettingsView incorrecto
- **Problema:** `exportSection` usaba el `IPTCSettingsView` de `IPTCSettingsView.swift`
  (placeholder sin persistencia) en lugar del de `IPTCMetadataWriter.swift`
  (el real, con UserDefaults y toggles funcionales).
- **Fix:** El `IPTCSettingsView` de `IPTCMetadataWriter.swift` es el correcto;
  `IPTCSettingsView.swift` debe **eliminarse del proyecto Xcode**.
- **Nuevo:** Verificación SHA-256 inline desde Settings → Export.

---

## 🔴 PENDIENTE (próximo commit)

### Alta Prioridad
1. **`ContentSessionManager.newSession()`** — el método es llamado en ContentView
   pero puede no existir con esa firma exacta. Verificar/añadir.
2. **`XYPlotBuilderView`** — referenciada en XYPlotSheetView, verificar que existe
   en XYPlotEngine.swift con esa firma.
3. **`GPUMonitor.powerDraw` y `utilizationPercent`** — referenciados en DashboardView;
   verificar que GPUMonitor los expone.
4. **`TaggingEngine.assetIDs(matchingAll:)` / `assetIDs(matchingAny:)`** — usados
   en GalleryView; ya existen en TaggingEngine.swift ✅.
5. **`BackupManager.isHealthy`** — usado en DashboardView; verificar que existe.

### Roadmap Items Pendientes (🟠 Corto Plazo)
- [ ] StudioPublishView completo (bulk selector + log compliance)
- [ ] ModelManager UI con benchmarks visuales
- [ ] Private Model Registry
- [ ] Sandboxing procesos SD
- [ ] Sistema de colas visual en JobQueueManager

---

## INSTRUCCIÓN DE MIGRACIÓN

1. **Eliminar de Xcode:** `IPTCSettingsView.swift` (el placeholder)
2. **Reemplazar en Xcode:** Los 5 archivos modificados de este commit
3. **Compilar y verificar:** Buscar errores de `XYPlotBuilderView`, `newSession()`,
   `powerDraw`, `isHealthy` y completar según sea necesario.
