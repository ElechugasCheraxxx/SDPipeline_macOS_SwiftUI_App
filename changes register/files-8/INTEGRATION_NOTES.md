# Commit Fundacional — Puntos de Integración
# Cambios exactos en archivos existentes para conectar los 5 archivos nuevos.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SDPipelineApp.swift — Arranque con VaultManager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REEMPLAZAR el body por:

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(VaultManager.shared)
                .environmentObject(AssetStore.shared)
                .sheet(isPresented: Binding(
                    get:  { VaultManager.shared.showFirstRunSheet },
                    set:  { VaultManager.shared.showFirstRunSheet = $0 }
                )) {
                    VaultSetupSheet()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .task {
            VaultManager.shared.checkFirstRun()  // ← muestra sheet si no hay vault
        }
    }


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SDService.swift — Guardar asset después de generar
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Al final del bloque `do { ... }` en generate(), justo antes de:
    stage = .done
    progressText = "Done! ✓"

AÑADIR:

    // Guardar en vault + Core Data
    await AssetStore.shared.saveAsset(
        image:   nsImage,
        request: request,
        seed:    sdResponse.parameters?.seed,
        sessionTag: activeSessionTag  // propiedad @Published en SDService
    )


AÑADIR propiedad en SDService:
    @Published var activeSessionTag: String? = nil


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ContentView.swift — Validación de seguridad en parseJSON()
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En parseJSON(), justo después de:
    let json = try JSONSerialization.jsonObject(with: data)
    parseError = nil; sdService.stage = .building

AÑADIR:

    // Validar JSON contra blacklist ANTES de parsear el prompt
    let safetyResult = PromptSafetyFilter.validateJSON(json)
    PromptSafetyFilter.logResult(safetyResult, prompt: jsonInput)

    switch safetyResult {
    case .blocked(let reason, _):
        parseError = reason
        sdService.stage = .error
        return
    case .flagged(let warnings):
        safetyWarnings = warnings  // @State var safetyWarnings: [String] = []
    case .allowed:
        safetyWarnings = []
    }


En generate(), justo antes de crear SDRequest:

    // Validar prompt final
    let promptCheck = PromptSafetyFilter.validatePrompt(
        positive: parsedPrompt,
        negative: settings.negativePrompt
    )
    if promptCheck.isBlocked {
        sdService.errorMessage = promptCheck.userMessage
        sdService.stage = .error
        return
    }


AÑADIR @State en ContentView:
    @State private var safetyWarnings: [String] = []


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Color(hex:) extension — ya existe en ModelBuilderView
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

VaultSetupSheet usa Color(hex:). Mover la extensión a un
archivo compartido Extensions.swift o verificar que sea
accesible desde VaultManager.swift.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Xcode: No se necesita .xcdatamodeld
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

El modelo Core Data se define programáticamente en
AssetStore.swift (NSManagedObjectModel.sdPipelineStudioModel).
NO crear un .xcdatamodeld — el modelo se crea en código.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Entitlements necesarios
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En SDPipeline.entitlements añadir:
  com.apple.security.files.user-selected.read-write  → YES
  com.apple.security.network.client                  → YES  (ya existe)

Esto permite el NSOpenPanel para seleccionar el vault root.
