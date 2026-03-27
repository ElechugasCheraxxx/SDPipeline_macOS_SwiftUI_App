# COMMIT8_INTEGRATION.md
# 5 engines nuevos — integración en ContentView + generate()

---

## Archivos del commit

| Archivo | Color acento | Descripción |
|---|---|---|
| BatchEngine.swift | `#60a5fa` | Batch txt2img, grid de resultados |
| PostProductionEngine.swift | `#34d399` | Upscale + Face restore via /extra-single-image |
| ModelManager.swift | `#f472b6` | Switch de modelos, registry privado, benchmarks |
| NSFWDetector.swift | — | Detector post-generación, prompt scorer + CLIP |
| PublishEngine.swift | `#fb923c` | Export por plataforma, log compliance |

---

## 1. ContentView — @StateObject (añadir los 5)

```swift
@StateObject private var batchEngine    = BatchEngine.shared
@StateObject private var postProd       = PostProductionEngine.shared
@StateObject private var modelManager   = ModelManager.shared
@StateObject private var nsfwDetector   = NSFWDetector.shared
@StateObject private var publishEngine  = PublishEngine.shared
```

---

## 2. centerPanel — añadir los 5 paneles

```swift
// Debajo de ScenePickerView:

ModelManagerView(baseURL: $settings.sdBaseURL)
    .padding(.horizontal, 4)

Divider().background(Color.white.opacity(0.07))

BatchBuilderView(
    basePrompt:   $parsedPrompt,
    baseNegative: $settings.negativePrompt,
    baseURL:      $settings.sdBaseURL,
    width:        $settings.width,
    height:       $settings.height
)
.padding(.horizontal, 4)

Divider().background(Color.white.opacity(0.07))

PostProductionView(
    baseURL:     $settings.sdBaseURL,
    sourceImage: sdService.generatedImage
)
.padding(.horizontal, 4)
```

---

## 3. generate() — hook NSFW post-generación

Después de recibir la imagen en generate():

```swift
// Detección NSFW asíncrona (no bloquea UI)
Task {
    let detection = await NSFWDetector.shared.detect(
        prompt:  finalPrompt,
        image:   sdService.generatedImage,
        baseURL: settings.sdBaseURL
    )
    if detection.action == .quarantine {
        // Opcional: mover imagen a carpeta de cuarentena
        print("⚠️ NSFW quarantine: \(detection.triggerWords)")
    }
}
```

---

## 4. generate() — benchmark automático por modelo

Después de recibir imagen, registrar tiempo de generación:

```swift
let genTime = Date().timeIntervalSince(generationStartTime)
if let model = ModelManager.shared.availableModels.first(where: {
    $0.title == settings.checkpoint
}) {
    let benchmark = ModelBenchmark(
        genTime:     genTime,
        steps:       settings.steps,
        width:       settings.width,
        height:      settings.height,
        samplerName: settings.samplerName
    )
    ModelManager.shared.addBenchmark(benchmark, to: model.sha256)
}
```

---

## 5. RightPanelView — tab "Publicar" (opcional, tercer tab)

```swift
enum PanelTab { case output, gallery, publish }

// En tabBar:
tabButton("Publicar", icon: "arrow.up.to.line", tab: .publish)

// En switch activeTab:
case .publish:
    PublishView(images: [sdService.generatedImage].compactMap { $0 })
```

---

## 6. ModelManager — fetch automático al conectar

En el `.task {}` de ContentView (junto a LoRAManager.configure):

```swift
.task {
    // ... código existente ...
    if !settings.sdBaseURL.isEmpty {
        await ModelManager.shared.fetchModels(baseURL: settings.sdBaseURL)
    }
}

// Y en onChange(of: webuiState):
.onChange(of: webuiState) { _, state in
    if state == .running {
        Task { await ModelManager.shared.fetchModels(baseURL: settings.sdBaseURL) }
    }
}
```

---

## Resumen de estado tras Commit 8

### ✅ 🟠 CORTO PLAZO completado:
- Batch processing + grid view ✓
- Post-procesamiento /extra-single-image ✓
- Botón Hi-Res Fix (via PostProd + Img2Img) ✓
- UI Model Manager + benchmarks ✓
- Private Model Registry ✓
- Detector NSFW post-generación ✓
- Logs de publicación con compliance ✓
- Watermark/Export System automatizado ✓

### ❌ Pendiente:
- Backups rclone
- Biblioteca IPTC/XMP/EXIF
- Encriptación imágenes y prompts
- Zero-Knowledge Logs
- Sandboxing SD / Hardening
- Política de privacidad y T&Cs
