import Foundation

// MARK: - ReusableSettings
// Snapshot ligero de los parámetros de una generación pasada.
// Se pasa desde GalleryView → RightPanelView → ContentView para
// "reutilizar" los settings de una imagen anterior en el pipeline activo.
// NO contiene la imagen — solo metadatos de generación.

struct ReusableSettings {
    var seed:           Int
    var steps:          Int
    var cfgScale:       Double
    var samplerName:    String
    var width:          Int
    var height:         Int
    var promptPositive: String
    var promptNegative: String
    var checkpoint:     String
    var sessionTag:     String?
    var loraWeights:    [String: Double]

    // Inicializador desde GeneratedAsset (Core Data)
    init(from asset: GeneratedAsset) {
        self.seed           = Int(asset.seed)
        self.steps          = Int(asset.steps)
        self.cfgScale       = asset.cfgScale
        self.samplerName    = asset.samplerName ?? "DPM++ 2M Karras"
        self.width          = Int(asset.width)
        self.height         = Int(asset.height)
        self.promptPositive = asset.promptPositive ?? ""
        self.promptNegative = asset.promptNegative ?? ""
        self.checkpoint     = asset.checkpoint ?? ""
        self.sessionTag     = asset.sessionTag
        self.loraWeights    = asset.loraWeights
    }

    // Inicializador manual (para tests / presets)
    init(
        seed:           Int    = -1,
        steps:          Int    = 28,
        cfgScale:       Double = 7.0,
        samplerName:    String = "DPM++ 2M Karras",
        width:          Int    = 512,
        height:         Int    = 768,
        promptPositive: String = "",
        promptNegative: String = "",
        checkpoint:     String = "",
        sessionTag:     String? = nil,
        loraWeights:    [String: Double] = [:]
    ) {
        self.seed           = seed
        self.steps          = steps
        self.cfgScale       = cfgScale
        self.samplerName    = samplerName
        self.width          = width
        self.height         = height
        self.promptPositive = promptPositive
        self.promptNegative = promptNegative
        self.checkpoint     = checkpoint
        self.sessionTag     = sessionTag
        self.loraWeights    = loraWeights
    }
}
