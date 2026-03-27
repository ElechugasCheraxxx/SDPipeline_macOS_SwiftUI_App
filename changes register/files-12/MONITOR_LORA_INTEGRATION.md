# MONITOR_LORA_INTEGRATION.md
# Parches para integrar GPUMonitor + LoRAManager en el proyecto existente
# Aplica en este orden: SDPipelineApp → ContentView → SDService (opcional)

---

## 1. SDPipelineApp.swift — arranque de monitores

En `.task {}` del WindowGroup, añadir al final del bloque:

```swift
.task {
    vault.checkFirstRun()
    LicenseVault.shared.generateAllTemplates()
    
    // ← NUEVO
    GPUMonitor.shared.detectDevice()
}
```

---

## 2. ContentView.swift — seis parches

### 2a. @StateObject para LoRAManager

Añadir al bloque de @State / @StateObject (junto a assetStore):

```swift
@StateObject private var loraManager = LoRAManager.shared
```

### 2b. .task {} — configurar y arrancar monitores cuando SD esté online

Sustituir el .task{} actual por:

```swift
.task {
    sdService.launchWebUI(
        scriptPath: settings.webuiScriptPath,
        baseURL: settings.sdBaseURL
    )
    GPUMonitor.shared.configure(baseURL: settings.sdBaseURL)
    LoRAManager.shared.configure(baseURL: settings.sdBaseURL)
}
.onChange(of: sdService.webuiState) { _, state in
    if case .online = state {
        GPUMonitor.shared.startPolling(interval: 6)
        Task { await LoRAManager.shared.fetchLoRAs() }
    }
}
```

### 2c. webuiStatusBar — añadir GPUMonitorBar

En el HStack de webuiStatusBar, después del botón "Re-launch":

```swift
Divider().frame(height: 14).background(Color.white.opacity(0.15))
GPUMonitorBar()
```

### 2d. centerPanel — añadir LoRAManagerView ANTES del botón Generate

Dentro del ScrollView del centerPanel, justo antes del Divider y el botón
"Parse & Build Prompt" (o después del último `Divider`), añadir:

```swift
Divider().background(Color.white.opacity(0.07))
LoRAManagerView()
    .padding(.horizontal, 4)

// Si quieres el panel GPU expandido también en settings:
// GPUStatusPanel()
//     .padding(.horizontal, 4)
```

### 2e. generate() — inyectar LoRAs en el prompt

En la función `generate()`, antes de construir el SDRequest, cambiar la
línea donde se usa `parsedPrompt` por:

```swift
// Inyectar tokens LoRA seleccionados al prompt positivo
let finalPrompt = LoRAManager.shared.inject(into: parsedPrompt)
```

Y usar `finalPrompt` en lugar de `parsedPrompt` al construir el SDRequest:

```swift
let req = SDRequest(
    prompt:         finalPrompt,   // ← era parsedPrompt
    negativePrompt: settings.negativePrompt,
    ...
)
```

### 2f. generate() — pre-check VRAM antes de enviar

Al inicio de `generate()`, antes de llamar a `sdService.generate()`:

```swift
GPUMonitor.shared.runPreCheck(
    requestedWidth:  settings.width,
    requestedHeight: settings.height
)
// Opcional: bloquear si hay memoria crítica
if case .critical(let msg) = GPUMonitor.shared.preCheckStatus {
    // Mostrar alerta o simplemente loguear — la generación continuará de todas formas
    // porque A1111 tiene su propio manejo de OOM. Esto es solo visual.
    print("⚠️ GPUMonitor: \(msg)")
}
```

---

## 3. Settings persistencia (opcional pero recomendado)

Si quieres que el `settings.sdBaseURL` actualice los monitores al cambiar:

```swift
.onChange(of: settings.sdBaseURL) { _, newURL in
    GPUMonitor.shared.configure(baseURL: newURL)
    LoRAManager.shared.configure(baseURL: newURL)
}
```

---

## 4. Checklist de archivos a añadir al proyecto Xcode

- [ ] GPUMonitor.swift   → Target: SDPipeline
- [ ] LoRAManager.swift  → Target: SDPipeline

Frameworks necesarios (ya disponibles en macOS SDK):
- Foundation ✓
- AppKit     ✓
- SwiftUI    ✓
- Darwin (para sysctlbyname / vm_statistics64) ✓

No se necesitan paquetes externos.

---

## 5. Resultado final

Con estos parches:
- La barra de estado WebUI mostrará un widget MPS/CUDA con barra de RAM en tiempo real
- El center panel tendrá un LoRA Manager colapsable con lista, búsqueda y peso por slider
- Los tokens `<lora:name:weight>` se inyectarán automáticamente al prompt antes de cada generación
- Antes de cada generación se ejecutará un pre-check de VRAM y se mostrará advertencia si el margen es ajustado
- Los monitores se inician solos cuando A1111 reporta estado `.online`
