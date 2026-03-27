import Foundation

// MARK: - SD API Models

struct SDRequest: Codable {
    var prompt: String
    var negative_prompt: String
    var steps: Int
    var cfg_scale: Double
    var width: Int
    var height: Int
    var sampler_name: String
    var seed: Int

    init(
        prompt: String,
        negativePrompt: String = "",
        steps: Int = 20,
        cfgScale: Double = 7.0,
        width: Int = 512,
        height: Int = 512,
        samplerName: String = "Euler a",
        seed: Int = -1
    ) {
        self.prompt = prompt
        self.negative_prompt = negativePrompt
        self.steps = steps
        self.cfg_scale = cfgScale
        self.width = width
        self.height = height
        self.sampler_name = samplerName
        self.seed = seed
    }
}

struct SDResponse: Codable {
    let images: [String]
    let parameters: SDResponseParameters?
    let info: String?
}

struct SDResponseParameters: Codable {
    let prompt: String?
    let seed: Int?
    let steps: Int?
}

// MARK: - Pipeline State

enum PipelineStage: String, CaseIterable {
    case idle       = "Idle"
    case parsing    = "Parsing JSON"
    case building   = "Building Prompt"
    case sending    = "Sending to SD"
    case receiving  = "Receiving Image"
    case done       = "Done"
    case error      = "Error"
}

// MARK: - Generation Settings

struct GenerationSettings {
    var negativePrompt: String = "ugly, blurry, low quality, deformed, nsfw"
    var steps: Int = 20
    var cfgScale: Double = 7.0
    var width: Int = 512
    var height: Int = 512
    var samplerName: String = "Euler a"
    var seed: Int = -1
    var sdBaseURL: String = "http://127.0.0.1:7860"

    static let samplers = [
        "Euler a", "Euler", "LMS", "Heun", "DPM2",
        "DPM2 a", "DPM++ 2S a", "DPM++ 2M", "DPM++ SDE",
        "DPM fast", "DPM adaptive", "DDIM", "PLMS"
    ]

    static let resolutions = [
        (512, 512), (512, 768), (768, 512),
        (768, 768), (640, 480), (1024, 576), (576, 1024)
    ]
}

// MARK: - Prompt Building Helpers

struct PromptBuilder {
    /// Flattens any JSON value into descriptive text tokens
    static func buildPrompt(from json: Any, prefix: String = "") -> String {
        var tokens: [String] = []
        extract(value: json, key: prefix, into: &tokens)
        return tokens.joined(separator: ", ")
    }

    private static func extract(value: Any, key: String, into tokens: inout [String]) {
        switch value {
        case let dict as [String: Any]:
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                extract(value: v, key: k, into: &tokens)
            }
        case let array as [Any]:
            for item in array {
                extract(value: item, key: key, into: &tokens)
            }
        case let str as String where !str.isEmpty:
            // Skip keys that look like IDs or metadata
            let lowKey = key.lowercased()
            if lowKey.contains("id") || lowKey.contains("timestamp") || lowKey.contains("url") {
                return
            }
            tokens.append(str)
        case let num as NSNumber:
            _ = num // skip numeric values by default
        default:
            break
        }
    }

    /// If the JSON already contains an explicit "prompt" key, extract it directly
    static func extractDirectPrompt(from json: Any) -> String? {
        guard let dict = json as? [String: Any] else { return nil }
        if let p = dict["prompt"] as? String, !p.isEmpty { return p }
        return nil
    }
}
