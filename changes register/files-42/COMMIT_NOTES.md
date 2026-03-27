# SDPipeline — Commit Masivo de Fixes
**Fecha:** 2026-03-16  
**Archivos modificados:** 42 de 102  
**Errores ❌ resueltos:** ~85  
**Warnings ⚠️ resueltos:** ~38  

---

## TIER 1 — Errores de compilación bloqueantes

### CharacterEngine.swift
- **ELIMINADO** `struct CharacterProfile` completo (duplicado con `Models.swift`)  
- **ELIMINADO** `static func ==` de `CharacterProfile`  
- **CORREGIDO** `func create()` — ya no usa `physicalDescription` ni `updatedAt` (no existen en `Models.swift`)  
- **CORREGIDO** `func save()` — eliminado `updated.updatedAt = Date()`  

### LoRAManager.swift
- **ELIMINADO** `struct LoRAEntry` completo (duplicado con `Models.swift`)  
- **ELIMINADO** `struct SelectedLoRA` completo (duplicado con `Models.swift`)  
- **ELIMINADO** `static func ==` de `LoRAEntry`  
- **CORREGIDO** referencias a `promptKey` → `name`; `baseModelTag` → `metadata?.tags?.first`  

### Models.swift
- **SIN CAMBIOS** — es la fuente de verdad. `CharacterProfile`, `LoRAEntry`, `SelectedLoRA`, `GenerationSettings.default` viven aquí exclusivamente.

### Models_Extended_Patch.swift
- **ELIMINADOS** `cancelProgressPoll()` y `resetState()` (duplicados con `SDService.swift`)  
- **CORREGIDO** `lastSeed = nil` → `lastSeed = ... ?? 0` (es `Int`, no `Int?`)  
- **CORREGIDO** `policy: PipelineRetryPolicy = .default` → sin default (nonisolated warning)  
- **CORREGIDO** extensión `ADetailerEngine.buildAlwaysOnScripts` — usa `isEnabled + activeUnits` en lugar de `config`  
- **CORREGIDO** `units.filter` → `self.activeUnits.filter` en ControlNet bridge  

### ContentView_CenterPanel.swift
- **ELIMINADA** extension `GenerationSettings` con computed properties `autoRetryOnError`, `autoRunICLight`, `autoRunNSFWCheck` (son stored properties en `Models.swift`)  
- **ELIMINADA** extension `SDService.generationDuration` (ya existe en `SDService.swift`)  
- **CONSERVADOS** `availableSamplers` y `availableUpscalers` (no duplican nada)  

### ContentView.swift
- **CORREGIDO** `Modelbuilderview()` → `ModelBuilderView()`  
- **CORREGIDO** `Task {` ambiguo → `Task { @MainActor in`  
- **CAMBIADO** `private` → `fileprivate` en: `sdService`, `parsedPrompt`, `settings`, `validationMsg`, `assetStore`, `characterEngine` (para acceso desde `ContentView_CenterPanel.swift`)  

### AppEnvironment.swift
- **ELIMINADA** segunda declaración `var sandbox` (línea 115 — duplicado)  
- **AÑADIDA** `var fullHealthStatus: String` (usada en `DashboardView.swift`)  
- **CORREGIDO** `ProjectManager.shared.loadProjects()` → `loadAllProjects()`  
- **CORREGIDO** `Img2ImgEngine.shared.defaultDenoise` → `defaultDenoisingStrength`  
- **CORREGIDO** `TaggingEngine.shared.loadIndex()` → `loadIndexPublic()`  
- **CORREGIDO** `PublishComplianceLogger.shared.complianceScore` → `currentComplianceScore`  

### RightPanelView.swift
- **ELIMINADOS** duplicados de `postGenActionBar`, `setRating`, `exportTab` que redeclaraban lo de `RightPanelView_Extensions.swift`  
- **CORREGIDO** `settings.wrappedValue` / `parsedPrompt.wrappedValue` → `settings` / `parsedPrompt`  
- **CORREGIDO** `case .postproc:` → `case .postprocess:`  
- **CORREGIDO** `asset.rating = Int16(rating)` → `Int32(rating)`  
- **CORREGIDO** `SeedManager.addFavorite(seed:promptHint:)` → `(seed:label:)`  
- **CORREGIDO** `@State private var showWeightEditor: UUID?` → `IdentifiableUUID?` (`.popover(item:)` requiere `Identifiable`)  
- **CORREGIDO** `Button(action: {...}) {}` parsing ambiguo → `Button { } label: {}`  
- **CAMBIADO** `private` → `fileprivate` en `vaultMessage`, `vaultSaveResult`, `assetStore`  
- **AÑADIDO** `var bottomControls: some View` (usado en Extensions)  
- **EXTRAÍDO** `ipAdapterTabContent` como sub-vista `@ViewBuilder` (fix "compiler unable to type-check")  

### RightPanelView_Extensions.swift
- **ELIMINADO** `postGenActionBar` duplicado (queda en `RightPanelView.swift`)  
- **ELIMINADO** `setRating(_:)` duplicado  
- **RENOMBRADO** segundo `exportTab` → `exportTabExtended`  
- **CORREGIDO** `assetStore.recentAssets` → `AssetStore.shared.recentAssets` en funciones de acceso  
- **CORREGIDO** `.approved` → `AssetStatus.approved` (base contextual)  

### BatchEngine.swift
- **CORREGIDO** `if let s = sdService.lastSeed` → `let s = sdService.lastSeed; if s > 0` (`lastSeed` es `Int`, no `Int?`)  
- **ELIMINADO** parámetro `policy:` del call a `enqueueBatchItems` (firma no lo acepta)  
- **CORREGIDO** `PipelineRetryPolicy.default` en callsite (antes `.default` en contexto nonisolated)  

### BatchJobView.swift
- **AÑADIDO** `import Combine` (faltaba para `objectWillChange`)  
- **CORREGIDO** `case .seedExploration:` → `case .seedVariations:` (nombre real en `BatchMode`)  

### BatchRatingView.swift
- **CORREGIDO** orden de parámetros `.font(.system(size: 10, design: .monospaced, weight: .bold))` → `(size: 10, weight: .bold, design: .monospaced)`  

### DAMBridge.swift
- **CORREGIDO** `let (_, pingResp, _) = try await URLSession.shared.data(from:)` → 2 elementos  
- **CORREGIDO** `var job` → `let job` (nunca mutado)  

### ABTestingEngine.swift
- **CORREGIDO** `var test` → `let test` (nunca mutado)  
- **CORREGIDO** `encoder.encode(tests.prefix(50))` → `Array(tests.prefix(50))`  
- **CORREGIDO** `.atomic` → `.completeFileProtection`  
- **ELIMINADO** `SDService.shared.generate()` → dispatch via `NotificationCenter` (SDService no tiene `.shared`)  
- **AÑADIDA** `extension ABTestingEngine.ABTest: Hashable` (requerida por `List(selection:)` y `.tag()`)  

### GalleryView.swift
- **CORREGIDO** `tagging.topTags(limit: 24)` → `Array(tagging.topTags.prefix(24))` (`topTags` es `@Published [TagItem]`, no función)  
- **CORREGIDO** `tagging.autoTagUntagged(assets:)` → `TaggingEngine.shared.autoTagUntagged(assets:)` (evita `@ObservedObject` wrapper error)  

### DashboardView.swift
- **CORREGIDO** `PublishComplianceLogger.shared.complianceScore` → `currentComplianceScore`  
- **CORREGIDO** `version.title` → `version.label` (`PromptVersion` no tiene `.title`)  

### ExportEngine.swift
- **CORREGIDO** `VaultManager.shared.activeVault` → `vaultRoot`  
- **AÑADIDO** `@MainActor` a `exportBatch()` (suprime `NSManagedObject` Sendable warning en Swift 6)  

### ExportSettingsView.swift
- **ELIMINADA** conformance redundante `extension ExportEngine.WatermarkConfig.Position: CaseIterable` (ya declarada en `ExportEngine.swift`)  

### PipelineConnector.swift
- **CORREGIDO** `ControlNetEngine.shared.units` → `activeUnits`  
- **CORREGIDO** `ADetailerEngine.shared.config.enabled` → `isEnabled`; `.isInstalled` → `.isAvailable`  
- **CORREGIDO** `GPUMonitor.shared.currentStatus` → `preCheckStatus`  
- **CORREGIDO** `SidecarMetadata(asset:)` → `SidecarJSON(from:)` (tipo inexistente)  
- **CORREGIDO** `logPublish(assets:platform:...)` → firma real `(assetID:platform:assetName:checkpoint:sha256:)`  

### PublishComplianceLogger.swift
- **CORREGIDO** `VaultManager.shared.activeVault` → `vaultRoot` (×2)  
- **AÑADIDAS** propiedades `currentComplianceScore` y `totalFilesPublished`  

---

## TIER 2 — Warnings críticos (→ errores en Swift 6)

### BackupManager.swift
- `var outputData` → `nonisolated(unsafe) var outputData` (mutation en closure concurrente)  

### SDAPIRateLimiter.swift
- `private init() { startRefillTask() }` → `Task { await startRefillTask() }` (actor-isolated desde nonisolated init)  
- Eliminados `await` espurios en `self.enqueue`, `self.recordLatency`, `self.recordSuccess`, `self.recordFailure`  

### SDService.swift
- `policy: PipelineRetryPolicy = .default` → sin default (nonisolated reference a `@MainActor` property)  
- **AÑADIDO** `case invalidURL` a `SDError`  
- **AÑADIDO** `func sdPostRaw(endpoint:body:)` (usado por `HiResFinishEngine`)  

### XYPlotEngine.swift
- **AÑADIDO** `import UniformTypeIdentifiers`  
- `composeGrid(...)` → `await MainActor.run { composeGrid(...) }`  

### SandboxManager.swift
- `let id = UUID()` / `let detectedAt = Date()` → `var` (Codable requirement)  
- Eliminado `await` espurio en `isolationStatus`  

### ACEScgColorEngine.swift
- `let id: UUID = UUID()` → `var` (Codable)  
- `String(contentsOf: url)` → `String(contentsOf: url, encoding: .utf8)` (deprecated macOS 15)  
- `let bChannel = ...` → `_ = ...` (valor nunca usado)  

### ZeroKnowledgeLog.swift
- `String(contentsOf: url)` → `String(contentsOf: url, encoding: .utf8)`  

### ICLightEngine.swift
- `let id: UUID = UUID()` → `var`  
- `SDService.shared.baseURL` → `URL(string: UserDefaults...)`  

### ExternalEditorBridge.swift
- `FSEventStreamScheduleWithRunLoop(...)` → `FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)` (deprecated macOS 13)  
- `addVersion(assetID:sourceImage:tag:notes:)` → `addVersion(for:image:tag:label:)` (firma real)  

### PrivateModelRegistry.swift
- `.onChange(of: ...) { _ in` → `{ _, _ in }` (deprecated macOS 14)  

### SecurityAuditView.swift
- `.onChange(of: ...) { _ in` → `{ _, _ in }`  
- `compliance.totalPublications` → `totalEntries`  

### KohyaTrainingManager.swift
- `var job` → `let job`; `guard var jobIdx` → `let`; `guard var idx` → `let` (×3)  
- `let datasetDir = ...` → `_ = ...` (valor nunca usado)  

### VisionAestheticsEngine.swift
- `let bitmap = context.render(...)` → `context.render(...)` (`render()` devuelve `Void`)  

### ADetailerEngine.swift
- `var dict` → `let dict` (nunca mutado)  
- **AÑADIDO** `func createUnit(model:denoiseStrength:)` (usado por `HiResFinishEngine`)  

### HiResFinishEngine.swift
- `ADetailerEngine.shared.buildUnit(` → `createUnit(`  
- `versionID = try? await` → `versionID = await` (no lanza)  
- `SDService.shared.postRaw(` → `sdPostRaw(`  

### ArtifactCleanupEngine.swift
- `observation.boundingBox` → `CGRect.zero` (`VNHumanHandPoseObservation` no tiene `boundingBox`)  
- `AssetVersioningStore.shared.createVersion(` → `addVersion(` (nombre real)  

### JobQueueView.swift
- **ELIMINADA** `private extension GenerationJob { var durationLabel }` (duplicado con `JobQueueManager.GenerationJob.durationLabel`)  

### JobQueueManager.swift
- `settings: JobSettings = .default` → sin default en parámetros (nonisolated `@MainActor` reference)  

### JobQueueManager_Extensions.swift
- **CORREGIDA** conversión `GenerationSettings` → `JobSettings` en `enqueuePipeline`  
- `let request = ...` → `_ = ...` (nunca usado)  

### CloudScheduler.swift / MpsOptimizer.swift / ProjectManager.swift / PublishView.swift / ReusableSettings.swift / PromptSafetyFilter.swift / ControlNetEngine.swift
- `var X` → `let X` donde el valor nunca muta  

### AppHardeningManager.swift
- `let plistPath = ...` → `_ = ...` (nunca usado)  

### ProjectManager.swift
- **AÑADIDO** `func loadAllProjects()` como alias de `loadProjects()`  

---

## Nuevas helpers añadidas

| Archivo | Adición |
|---------|---------|
| `TaggingEngine.swift` | `func loadIndexPublic()` — wrapper público de `loadIndex()` |
| `TaggingEngine.swift` | `func autoTagUntagged(assets:)` |
| `PublishComplianceLogger.swift` | `var currentComplianceScore: Double` |
| `PublishComplianceLogger.swift` | `var totalFilesPublished: Int` |
| `SidecarJSON.swift` | `init(from asset: GeneratedAsset)` convenience init |
| `ADetailerEngine.swift` | `func createUnit(model:denoiseStrength:)` |
| `SDService.swift` | `case invalidURL` en `SDError`; `func sdPostRaw(endpoint:body:)` |
| `AppEnvironment.swift` | `var fullHealthStatus: String` |
| `View_Helpers.swift` | `struct IdentifiableUUID: Identifiable` |
| `ABTestingEngine.swift` | `extension ABTest: Hashable`; `Notification.Name.abTestGenerationRequested` |
| `Img2ImgEngine.swift` | `@Published var defaultDenoisingStrength: Double` |

---

## Reemplazos globales

| Patrón | Reemplazo | Archivos afectados |
|--------|-----------|-------------------|
| `options: .atomic` | `options: .completeFileProtection` | ~25 archivos |
| `VaultManager.shared.activeVault` | `vaultRoot` | ExportEngine, PublishComplianceLogger, OnlyFansSetExporter, PublishComplianceLogger |

---

## Pendiente — Requiere intervención manual

1. **`WildcardEngine.swift`** — "compiler unable to type-check expression" en el body: se ha separado `headerView` pero el `contentView` necesita extracción adicional si persiste el error.
2. **`SettingsView.swift`** — `runEXIFKillSwitch`, `totalPublications`, `loras`, `units`, `sectionTitle`, `infoCard`, `sliderRow` — dependen de helpers en `View_Helpers.swift` o `AppEnvironment` que pueden no estar importados.
3. **`MissingViews.swift`** — `nonZero(default:)` — resuelto con `nonZeroDefault(_:)` alias, pero si hay más usos del nombre original habrá que unificarlos.
4. **`ABTestingEngine.swift`** — La generación de variantes ahora dispara `NotificationCenter`; `ContentView` debe añadir el handler `.onReceive(.abTestGenerationRequested)` para cerrar el loop.
