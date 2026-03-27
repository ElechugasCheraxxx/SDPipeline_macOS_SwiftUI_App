# SDPipeline — macOS SwiftUI App

Stable Diffusion pipeline app: JSON → Prompt → Image.

## Setup in Xcode

1. **New Project** → macOS → App
   - Product Name: `SDPipeline`
   - Interface: SwiftUI
   - Language: Swift

2. **Replace files**: Delete the default `ContentView.swift` and drop in all 4 files:
   - `SDPipelineApp.swift`
   - `ContentView.swift`
   - `SDService.swift`
   - `Models.swift`

3. **Signing**: Xcode → Target → Signing & Capabilities → sign with your team.

4. **Network entitlement**: In `SDPipeline.entitlements` (or Signing tab), enable:
   - `com.apple.security.network.client` → YES  
   (or uncheck App Sandbox entirely for local dev)

5. **Run** with Stable Diffusion WebUI running: `python launch.py --api`

---

## JSON Format

Any JSON works. The parser auto-builds a prompt from string values.

### Auto-built from arbitrary JSON:
```json
{
  "subject": "a lone astronaut",
  "environment": "deep space, nebula background",
  "style": "cinematic, 8k, ultra-detailed",
  "mood": "ethereal, awe-inspiring",
  "lighting": "rim light, bioluminescent glow"
}
```

### Or provide a prompt directly:
```json
{
  "prompt": "a lone astronaut floating in deep space, cinematic 8k",
  "style": "photorealistic"
}
```

---

## Pipeline Stages

```
JSON Input  →  Parse  →  Prompt Builder  →  POST /sdapi/v1/txt2img  →  Image
```

Status indicator in the header shows each stage in real-time.

---

## SD API Requirements

- Stable Diffusion WebUI running with `--api` flag
- Default: `http://127.0.0.1:7860`
- Configurable in the Settings panel
