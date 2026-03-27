# Commit — Galería + Rating + Seed Management
# Integración exacta con ContentView.swift existente.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ContentView.swift — Reemplazar rightPanel por RightPanelView
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. En el HSplitView, REEMPLAZAR:

    rightPanel.frame(minWidth: 360, maxWidth: .infinity)

   POR:

    RightPanelView(
        sdService:        sdService,
        settings:         $settings,
        parsedPrompt:     $parsedPrompt,
        onGenerate:       generate,
        onSaveImage:      saveImage,
        onReuseSettings:  { reusable in
            settings.seed        = reusable.seed
            settings.steps       = reusable.steps
            settings.cfgScale    = reusable.cfgScale
            settings.samplerName = reusable.samplerName
            settings.width       = reusable.width
            settings.height      = reusable.height
            if !reusable.promptPositive.isEmpty { parsedPrompt = reusable.promptPositive }
            if !reusable.promptNegative.isEmpty { settings.negativePrompt = reusable.promptNegative }
        }
    )
    .frame(minWidth: 360, maxWidth: .infinity)

2. El var rightPanel existente en ContentView puede ELIMINARSE o
   mantenerse como backup comentado — ya no se usa.

3. Los sub-views (stageBadge, emptyStateView, generatingView, errorView)
   ya están copiados en RightPanelView. Pueden eliminarse de ContentView
   para evitar conflictos de nombre, o renombrarse con prefijo "cv_".


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SDService.swift — Guardar en PromptHistory post-generación
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En generate(), justo después de guardar el asset en AssetStore, añadir:

    // Registrar en historial de prompts
    PromptHistory.shared.record(
        positive: request.prompt,
        negative: request.negative_prompt,
        seed:     sdResponse.parameters?.seed ?? request.seed,
        assetID:  asset?.id?.uuidString
    )


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Models.swift — Añadir checkpoint a GenerationSettings
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

En struct GenerationSettings, añadir:

    var checkpoint: String = ""   // nombre del .safetensors activo


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  NOTA: padding(.vertical: 2) en RightPanelView.tabBar
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Corregir sintaxis: .padding(.vertical: 2) → .padding(.vertical, 2)
(error tipográfico en el archivo generado)
