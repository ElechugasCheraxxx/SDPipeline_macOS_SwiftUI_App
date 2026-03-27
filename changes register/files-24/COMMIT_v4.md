# Commit v4 — SDPipelineStudio

## Inventario completo del proyecto

### ✅ 100% IMPLEMENTADO (no requiere trabajo)
**SECCIÓN 1 — Infraestructura**
- VaultManager · AssetStore (Core Data) · SidecarJSON · BackupManager
- LicenseVault · IPTCMetadataWriter · IntegridadSHA-256

**SECCIÓN 3 — Seguridad**  
- SteganographyEngine · ExportEngine (dual export + EXIF scrub)
- PromptSafetyFilter · ZeroKnowledgeLog · NSFWDetector

**SECCIÓN 4 — Consistencia Creativa**
- CharacterEngine · SceneEngine · WildcardEngine

**SECCIÓN 5 — Generación Avanzada**
- Img2ImgEngine · BatchEngine · SeedManager · GPUMonitor · XYPlotEngine

**SECCIÓN 6 — Post-Procesamiento**
- PostProductionEngine · CinematicFilterEngine

**SECCIÓN 7-9 — UI + Publicación**
- JobQueueManager · ContentSessionManager · PublishEngine
- DashboardViewModel · PromptVersioningStore · TaggingEngine

---

## Bugs resueltos en este commit (v4)

### 1. DashboardView — 4 bugs de APIs
| Bug | Causa | Fix |
|-----|-------|-----|
| `GPUMonitor.vramFreeMB` | No existe | → `vramFree` (Int64 bytes) / `ramFree` en Apple Silicon |
| `GPUMonitor.powerDraw` | No existe | Eliminado del snapshot |
| `GPUMonitor.utilizationPercent` | No existe | Reemplazado por `preCheckStatus` badge |
| `BackupManager.isHealthy` | No existe | → `config.lastBackupOK` (Bool) |

### 2. ContentView — 2 bugs de APIs
| Bug | Causa | Fix |
|-----|-------|-----|
| `ContentSessionManager.newSession()` | El método se llama `.create()` | → `.create(title:category:)` |
| `XYPlotBuilderView` | No existe | → `XYPlotView(sdService:settings:parsedPrompt:)` |

### 3. PipelineConnector — 1 bug de API
| Bug | Causa | Fix |
|-----|-------|-----|
| `selectedLoRAs[x].promptKey` | `SelectedLoRA` no tiene `.promptKey` | → `.lora.name` |

### 4. SettingsView — 3 bugs
| Bug | Causa | Fix |
|-----|-------|-----|
| `backupMgr.lastBackupAt` | No existe en raíz | → `backupMgr.config.lastBackupAt` |
| `backupMgr.isHealthy` | No existe | → `backupMgr.config.lastBackupOK` |
| `gpu.vramFreeMB` | No existe | → `Double(gpu.vramFree) / 1_048_576.0` |

### 5. RightPanelView — 2 bugs
| Bug | Causa | Fix |
|-----|-------|-----|
| `Img2ImgEngine.shared.prepareForRefinement()` | No existe | → `.refine(image:prompt:negative:denoise:settings:baseURL:checkpoint:)` |
| `queue.enqueue(type:label:prompt:…)` | Firma incorrecta | → `enqueue(type:label:priority:metadata:)` |

---

## Nuevo feature en este commit

### RightPanelView: Tab "Cola" 
- Añadido `case queue = "Cola"` con `JobQueueView()`
- Badge rojo con número de jobs activos/pendientes
- Presets cinematográficos en barra quick-access sobre imagen

---

## PENDIENTE — Próximo commit de mayor impacto

### 🔴 Prioridad Crítica (sin implementar)
Nada crítico — toda la infraestructura existe.

### 🟠 Prioridad Alta — Features visuales faltantes
1. **StudioPublishView completo** — el existente es básico; falta:
   - Bulk selector con checkboxes
   - Preview por plataforma (crop, resize)
   - Log de publicación con compliance (timestamp, preset usado)
   
2. **CinematicFilterView** existe pero no está accesible desde UI principal
   — integrar como panel en Output o como sheet

3. **XYPlotView** solo abre desde menú; integrar botón en center panel
   junto a Batch Builder

4. **CharacterEngine + Img2ImgEngine** — Character Consistency System:
   `CharacterConsistencyView` que orquesta base image → img2img → pin seed

5. **ModelManager benchmarks** — `ModelRecordEditor` existe pero
   `ModelBenchmarkChart` no está creado todavía

### 🟡 Medio Plazo
- CLIP vector search (requiere embeddings externos)
- IP-Adapter / FaceID integration (requiere ControlNet instalado)
- Tiled upscaling (SUPIR)
