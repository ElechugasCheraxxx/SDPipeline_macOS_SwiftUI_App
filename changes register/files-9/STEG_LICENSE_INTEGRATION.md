# Commit — Esteganografía + Vault Legal
# Puntos de integración exactos con archivos existentes.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AssetStore.swift — Inyectar firma invisible post-guardado
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En saveAsset(), reemplazar:

    // Guardar PNG original
    guard let pngData = image.pngData() else { return nil }
    let origURL = vaultDir.appending(path: "\(baseName)_v001.orig.png")
    try? pngData.write(to: origURL)
    let sha256 = pngData.sha256Hex

POR:

    // 1. PNG raw de SD (sin tocar — referencia de integridad)
    guard let rawData = image.pngData() else { return nil }
    let sha256 = rawData.sha256Hex

    // 2. Incrustar firma esteganográfica en la copia de vault
    //    (el raw se guarda sin firma para tener referencia pura)
    let assetUUID = UUID()
    let signedData = SteganographyEngine.shared.embed(
        image:      image,
        assetID:    assetUUID,
        sessionTag: sessionTag,
        sha256:     sha256
    ) ?? rawData  // fallback al raw si falla la firma

    let origURL = vaultDir.appending(path: "\(baseName)_v001.orig.png")
    try? signedData.write(to: origURL)

Y en la creación del GeneratedAsset, usar:
    asset.id = assetUUID  // usar el mismo UUID que se firmó


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SDPipelineApp.swift — Inicializar vault legal al arranque
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En .task { } junto a checkFirstRun(), añadir:

    // Generar plantillas legales si no existen
    if VaultManager.shared.isConfigured {
        LicenseVault.shared.generateAllTemplates()
    }


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SDService.swift — Verificar licencia antes de generar
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En generate(), antes del URLRequest, añadir:

    // Verificar compliance de licencia del modelo activo
    if !settings.checkpoint.isEmpty {
        let compliance = await LicenseVault.shared.checkCompliance(
            checkpointName: settings.checkpoint
        )
        if case .blocked(_, let reason) = compliance {
            errorMessage = "Licencia bloqueada: \(reason)"
            stage = .error; isGenerating = false
            return
        }
    }

Añadir propiedad en GenerationSettings (Models.swift):
    var checkpoint: String = ""   // nombre del .safetensors activo


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Entitlements — Red necesaria para snapshot de licencias
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

com.apple.security.network.client → YES (ya existe)
LicenseVault descarga snapshots de licencia desde URLs externas
(CivitAI, HuggingFace) de forma best-effort en background Task.
No hay cambio necesario en entitlements.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Verificación de firma (uso futuro — rastreo filtraciones)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Para verificar si una imagen filtrada es tuya:

    let result = SteganographyEngine.shared.verify(image: suspectImage)
    switch result {
    case .valid(let payload):
        print("Imagen tuya — Asset: \(payload.assetID)")
        print("Sesión: \(payload.sessionTag ?? "sin tag")")
        print("Generada: \(Date(timeIntervalSince1970: payload.timestamp))")
    case .noSignature:
        print("Sin firma — no es tuya o fue procesada agresivamente")
    case .invalidSignature:
        print("Firma corrupta — posible recompresión fuerte")
    }

Esto se puede exponer en la UI como "Verificar imagen sospechosa"
arrastrando el archivo a la app (NSItemProvider / drag & drop).
