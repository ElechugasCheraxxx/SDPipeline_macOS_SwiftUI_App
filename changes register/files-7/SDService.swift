import Foundation
import AppKit

@MainActor
class SDService: ObservableObject {
    @Published var stage: PipelineStage = .idle
    @Published var generatedImage: NSImage?
    @Published var errorMessage: String?
    @Published var lastSeed: Int?
    @Published var isGenerating: Bool = false
    @Published var progressText: String = ""

    func generate(request: SDRequest, baseURL: String) async {
        isGenerating = true
        errorMessage = nil
        generatedImage = nil
        stage = .sending
        progressText = "Connecting to Stable Diffusion…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "Invalid URL: \(baseURL)/sdapi/v1/txt2img"
            stage = .error
            isGenerating = false
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300

        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            errorMessage = "Failed to encode request: \(error.localizedDescription)"
            stage = .error
            isGenerating = false
            return
        }

        progressText = "Generating (\(request.steps) steps)…"

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "SDPipeline", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "SDPipeline", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"])
            }

            stage = .receiving
            progressText = "Decoding image…"

            let decoder = JSONDecoder()
            let sdResponse = try decoder.decode(SDResponse.self, from: data)

            guard let base64String = sdResponse.images.first else {
                throw NSError(domain: "SDPipeline", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "No images in response"])
            }

            guard let imageData = Data(base64Encoded: base64String),
                  let nsImage = NSImage(data: imageData) else {
                throw NSError(domain: "SDPipeline", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 image"])
            }

            generatedImage = nsImage
            lastSeed = sdResponse.parameters?.seed
            stage = .done
            progressText = "Done! ✓"

        } catch {
            errorMessage = error.localizedDescription
            stage = .error
            progressText = ""
        }

        isGenerating = false
    }

    func checkHealth(baseURL: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/internal/ping") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
