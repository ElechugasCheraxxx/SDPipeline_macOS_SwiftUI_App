# CHARACTER_INTEGRATION.md
# Parches para integrar CharacterEngine en el proyecto existente
# Solo 3 parches, todos en ContentView.swift

---

## 1. ContentView.swift — @StateObject

Añadir junto a los otros @StateObject:

```swift
@StateObject private var characterEngine = CharacterEngine.shared
```

---

## 2. ContentView.swift — centerPanel (CharacterPickerView)

En el ScrollView del centerPanel, al inicio (justo antes o después de LoRAManagerView),
añadir:

```swift
CharacterPickerView()
    .padding(.horizontal, 4)

Divider().background(Color.white.opacity(0.07))
```

---

## 3. ContentView.swift — generate() (inyección de personaje)

En la función `generate()`, extender la línea de inyección de LoRAs:

```swift
// Inyectar personaje activo + LoRAs seleccionados
let withCharacter = CharacterEngine.shared.injectActiveCharacter(into: parsedPrompt)
let finalPrompt   = LoRAManager.shared.inject(into: withCharacter)

// Combinar negativos: settings + personaje activo
let finalNegative = [
    settings.negativePrompt,
    CharacterEngine.shared.activeCharacterNegative
]
.filter { !$0.isEmpty }
.joined(separator: ", ")
```

Y usar ambos en el SDRequest:

```swift
let req = SDRequest(
    prompt:         finalPrompt,    // ← era parsedPrompt
    negativePrompt: finalNegative,  // ← era settings.negativePrompt
    seed:           settings.seed,
    ...
)
```

---

## 4. RightPanelView.swift — pinear seed al personaje activo

En `saveToVault()`, después de guardar el asset, añadir:

```swift
// Si hay personaje activo, pinear el seed a ese personaje
if let seed = sdService.lastSeed,
   let character = CharacterEngine.shared.activeCharacter {
    CharacterEngine.shared.pinSeed(seed, to: character.id)
}
```

---

## 5. Añadir al proyecto Xcode

- [ ] CharacterEngine.swift → Target: SDPipeline

Sin dependencias externas adicionales.

---

## Flujo resultante

```
1. Usuario abre CharacterPickerView → selecciona "Valentina"
2. CharacterEngine aplica LoRAs de Valentina al LoRAManager automáticamente
3. En generate():
   - finalPrompt = "25 year old woman, curvy, warm olive skin, ..., <lora:valentina_v2:0.85>, [prompt de sesión]"
   - finalNegative = "[negativos settings] + [negativos de Valentina]"
4. Imagen generada → seed se pinea automáticamente a Valentina
5. Próxima sesión: seleccionar Valentina → sus seeds y LoRAs ya están listos
```
