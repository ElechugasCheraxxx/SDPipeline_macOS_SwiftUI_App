#if canImport(XCTest)
import XCTest
import CryptoKit
import Foundation
@testable import SDPipeline   // Ajusta al nombre exacto de tu target principal

// MARK: - SDPipelineTests v2
//
// Cambios v1 → v2:
//   🐛 FIX: Suite 09 GenerationSettings — añadidos tests de campos v2
//          (autoRetryOnError, clipSkip, karrasNoise, samplers incluye UniPC)
//   ✨ ADD: SUITE 14 — VaultCryptoEngineTests  (AES-GCM roundtrip, HMAC, SHA-256)
//   ✨ ADD: SUITE 15 — SteganographyEngineTests (payload codable, artistID, config)
//   ✨ ADD: SUITE 16 — PromptSafetyFilterTests_v2 (validate() wrapper, edge cases)
//   ✨ ADD: SUITE 17 — NSFWDetectorTests       (levels, policy, logResultZK alias)
//   ✨ ADD: SUITE 18 — Img2ImgRequestTests     (init, resize modes, inpaint fill)
//   ✨ ADD: SUITE 19 — ControlNetUnitTests     (toAPIDict, codable, ControlNetModule enum)
//   ✨ ADD: SUITE 20 — PromptDatabaseTests     (search, filter, CRUD)
// 20 suites · 130+ assertions

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 01 — PromptBuilderTests
// ─────────────────────────────────────────────────────────────────────────────

final class PromptBuilderTests: XCTestCase {

    func test_primaryPrompt_returnedVerbatim() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "gorgeous woman, studio lighting, 4k",
                "negative_prompt": "ugly, blurry, nsfw"
            ]
        ]
        let r = PromptBuilder.buildFromEditorialSchema(json)
        XCTAssertTrue(r.positive.contains("gorgeous woman"))
        XCTAssertEqual(r.negative, "ugly, blurry, nsfw")
    }

    func test_variationPrompts_allAppended() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "editorial model",
                "variation_prompts": ["red dress", "beach background"]
            ]
        ]
        let r = PromptBuilder.buildFromEditorialSchema(json)
        XCTAssertTrue(r.positive.contains("editorial model"))
        XCTAssertTrue(r.positive.contains("red dress"))
        XCTAssertTrue(r.positive.contains("beach background"))
    }

    func test_highLightingDrama_addsDramaticBoosters() {
        let json: [String: Any] = [
            "editorial_style_system": ["components": ["lighting_drama_0_10": 9,
                                                       "camera_storytelling_0_10": 8]],
            "brand_projection":       ["aspirational_level_0_10": 9],
            "camera_engine":          ["lens_mm": 85, "aperture": "f/1.8"]
        ]
        let r = PromptBuilder.buildFromEditorialSchema(json)
        XCTAssertTrue(r.positive.contains("dramatic studio lighting"))
        XCTAssertTrue(r.positive.contains("editorial photography"))
        XCTAssertTrue(r.positive.contains("ultra high resolution"))
        XCTAssertTrue(r.positive.contains("bokeh"))
        XCTAssertTrue(r.positive.contains("soft background blur"))
    }

    func test_noDuplicateTokens() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "portrait, portrait, portrait",
                "variation_prompts": ["portrait"]
            ]
        ]
        let r      = PromptBuilder.buildFromEditorialSchema(json)
        let tokens = r.positive.components(separatedBy: ", ").filter { !$0.isEmpty }
        XCTAssertEqual(tokens.count, Set(tokens).count, "No debe haber tokens duplicados")
    }

    func test_buildFlat_extractsAllLeafStrings() {
        let json: [String: Any] = ["a": "red", "b": ["c": "blue"], "e": ["yellow", "orange"]]
        let r = PromptBuilder.buildFlat(from: json)
        XCTAssertTrue(r.contains("red"))
        XCTAssertTrue(r.contains("blue"))
        XCTAssertTrue(r.contains("yellow"))
        XCTAssertTrue(r.contains("orange"))
    }

    func test_buildFlat_ignoresMetaKeys() {
        let json: [String: Any] = ["version": "1.0", "character_id": "char_001", "style": "cinematic"]
        let r = PromptBuilder.buildFlat(from: json)
        XCTAssertFalse(r.contains("1.0"))
        XCTAssertFalse(r.contains("char_001"))
        XCTAssertTrue(r.contains("cinematic"))
    }

    func test_extractDirectPrompt_returnsValue() {
        XCTAssertEqual(PromptBuilder.extractDirectPrompt(from: ["prompt": "a beautiful sunset"]),
                       "a beautiful sunset")
    }

    func test_extractDirectPrompt_nilForMissingKey() {
        XCTAssertNil(PromptBuilder.extractDirectPrompt(from: ["style": "editorial"]))
    }

    func test_extractDirectPrompt_nilForEmptyString() {
        XCTAssertNil(PromptBuilder.extractDirectPrompt(from: ["prompt": ""]))
    }

    func test_emptyDict_hasMinimumQualityBoosters() {
        let r = PromptBuilder.buildFromEditorialSchema([String: Any]())
        XCTAssertTrue(r.positive.contains("high quality"),
                      "Debe incluir booster mínimo cuando aspiration=0")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 02 — PromptSafetyFilterTests
// ─────────────────────────────────────────────────────────────────────────────

final class PromptSafetyFilterTests: XCTestCase {

    func test_blocksSchoolgirlTerm() {
        XCTAssertTrue(PromptSafetyFilter.validatePrompt(positive: "cute schoolgirl", negative: "").isBlocked)
    }

    func test_blocksForcedSex() {
        XCTAssertTrue(PromptSafetyFilter.validatePrompt(positive: "forced sex scene", negative: "").isBlocked)
    }

    func test_blocksLoli() {
        XCTAssertTrue(PromptSafetyFilter.validatePrompt(positive: "loli anime character", negative: "").isBlocked)
    }

    func test_blocksMinorSpanish() {
        XCTAssertTrue(PromptSafetyFilter.validatePrompt(positive: "niña inocente", negative: "").isBlocked)
    }

    func test_allowsCleanEditorialPrompt() {
        let r = PromptSafetyFilter.validatePrompt(
            positive: "editorial fashion model, studio lighting, 4k",
            negative: "ugly, blurry, deformed"
        )
        XCTAssertTrue(r.isAllowed)
        XCTAssertFalse(r.isBlocked)
        XCTAssertFalse(r.isFlagged)
    }

    func test_flagsSoftTermsWithoutBlocking() {
        let r = PromptSafetyFilter.validatePrompt(positive: "very young woman, innocent smile", negative: "")
        XCTAssertFalse(r.isBlocked)
        XCTAssertTrue(r.isFlagged)
    }

    func test_blockedResult_hasEmojiPrefix() {
        let r = PromptSafetyFilter.validatePrompt(positive: "child model", negative: "")
        XCTAssertTrue(r.userMessage?.hasPrefix("🚫") ?? false)
    }

    func test_allowedResult_nilMessage() {
        let r = PromptSafetyFilter.validatePrompt(positive: "fashion editorial", negative: "blurry")
        XCTAssertNil(r.userMessage)
    }

    func test_validateJSON_flagsMinorProtectionFalse() {
        let json: [String: Any] = [
            "safety_compliance_layer": [
                "minor_protection_enforced": false,
                "sexual_act_block": true,
                "explicit_content_block": true
            ]
        ]
        let r = PromptSafetyFilter.validateJSON(json)
        XCTAssertTrue(r.isFlagged || r.isBlocked)
    }

    func test_validateJSON_allowsFullyCompliantSchema() {
        let json: [String: Any] = [
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block": true,
                "explicit_content_block": true
            ],
            "generation_engine": ["primary_prompt": "editorial fashion model"]
        ]
        XCTAssertFalse(PromptSafetyFilter.validateJSON(json).isBlocked)
    }

    func test_validateJSON_blocksNestedHardTerms() {
        let json: [String: Any] = [
            "wardrobe_engine": ["notes": "schoolgirl uniform"],
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block": true,
                "explicit_content_block": true
            ]
        ]
        XCTAssertTrue(PromptSafetyFilter.validateJSON(json).isBlocked)
    }

    func test_filterResult_mutualExclusion() {
        let blocked: PromptSafetyFilter.FilterResult = .blocked(reason: "test", matchedTerms: ["x"])
        XCTAssertTrue(blocked.isBlocked);  XCTAssertFalse(blocked.isFlagged);  XCTAssertFalse(blocked.isAllowed)

        let flagged: PromptSafetyFilter.FilterResult = .flagged(warnings: ["w"])
        XCTAssertFalse(flagged.isBlocked); XCTAssertTrue(flagged.isFlagged);   XCTAssertFalse(flagged.isAllowed)

        let allowed: PromptSafetyFilter.FilterResult = .allowed
        XCTAssertFalse(allowed.isBlocked); XCTAssertFalse(allowed.isFlagged);  XCTAssertTrue(allowed.isAllowed)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 03 — SidecarJSONTests
// ─────────────────────────────────────────────────────────────────────────────

final class SidecarJSONTests: XCTestCase {

    func makeSidecar(enableHR: Bool = false) -> SidecarJSON {
        SidecarJSON(
            baseName:    "test_asset",
            version:     1,
            imageURL:    URL(fileURLWithPath: "/tmp/test_asset_v001.png"),
            request:     SDRequest(
                prompt: "editorial model", negativePrompt: "ugly, blurry",
                seed: 42, steps: 28, enableHR: enableHR,
                hrUpscaler: "4x-UltraSharp", hrScale: 2.0,
                hrSecondPassSteps: 15, denoisingStrength: 0.45
            ),
            seed:        42,
            modelName:   "realisticVision",
            checkpoint:  "realisticVision_v5.safetensors",
            vaeUsed:     "vae-ft-mse",
            loraWeights: ["beautify": 0.8, "detail": 0.6],
            sha256:      "abc123def456",
            sessionTag:  "Beach Session Mar 2025",
            sdVersion:   "1.9.4"
        )
    }

    func test_codableRoundtrip() throws {
        let original = makeSidecar()
        let decoded  = try JSONDecoder.iso8601.decode(SidecarJSON.self,
                            from: JSONEncoder.pretty.encode(original))
        XCTAssertEqual(decoded.baseName,                  original.baseName)
        XCTAssertEqual(decoded.sha256,                    original.sha256)
        XCTAssertEqual(decoded.schemaVersion,             "SDPipeline.Sidecar.v1")
        XCTAssertEqual(decoded.generation.seed,           42)
        XCTAssertEqual(decoded.generation.promptPositive, "editorial model")
        XCTAssertEqual(decoded.generation.samplerName,    "DPM++ 2M Karras")
        XCTAssertEqual(decoded.model.loraWeights["beautify"], 0.8)
        XCTAssertEqual(decoded.session.sdVersion,         "1.9.4")
        XCTAssertFalse(decoded.integrity.cleanVersionExists)
    }

    func test_saveAndLoadRoundtrip() throws {
        let original = makeSidecar()
        let tempURL  = FileManager.default.temporaryDirectory
            .appending(path: "test_\(UUID().uuidString).meta.json")
        try original.save(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let loaded = SidecarJSON.load(from: tempURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sha256, original.sha256)
        try? FileManager.default.removeItem(at: tempURL)
    }

    func test_loadReturnsNilForMissingFile() {
        XCTAssertNil(SidecarJSON.load(from: URL(fileURLWithPath: "/nonexistent/path.meta.json")))
    }

    func test_imageFilenameIsNotFullPath() {
        let s = makeSidecar()
        XCTAssertFalse(s.imageFilename.contains("/"))
        XCTAssertEqual(s.imageFilename, "test_asset_v001.png")
    }

    func test_hrValuesNilWhenDisabled() {
        let s = makeSidecar(enableHR: false)
        XCTAssertNil(s.generation.hrScale)
        XCTAssertNil(s.generation.hrSecondPassSteps)
        XCTAssertNil(s.generation.denoisingStrength)
    }

    func test_hrValuesSetWhenEnabled() {
        let s = makeSidecar(enableHR: true)
        XCTAssertEqual(s.generation.hrScale,           2.0)
        XCTAssertEqual(s.generation.hrSecondPassSteps, 15)
        XCTAssertEqual(s.generation.denoisingStrength, 0.45)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 04 — SandboxManagerTests
// ─────────────────────────────────────────────────────────────────────────────

final class SandboxManagerTests: XCTestCase {

    func test_defaultHost_isLocalhost() {
        XCTAssertEqual(SandboxManager.SandboxConfig().allowedHost, "127.0.0.1")
    }

    func test_defaultPort_is7860() {
        XCTAssertEqual(SandboxManager.SandboxConfig().allowedPort, 7860)
    }

    func test_killOnViolation_isFalseByDefault() {
        XCTAssertFalse(SandboxManager.SandboxConfig().killOnCriticalViolation)
    }

    func test_blockedEnvPrefixes_containAntiInjection() {
        let cfg = SandboxManager.SandboxConfig()
        XCTAssertTrue(cfg.blockedEnvironmentPrefixes.contains("DYLD_INSERT_LIBRARIES"))
        XCTAssertTrue(cfg.blockedEnvironmentPrefixes.contains("LD_PRELOAD"))
        XCTAssertTrue(cfg.blockedEnvironmentPrefixes.contains("DYLD_LIBRARY_PATH"))
    }

    func test_allowedEnvKeys_containEssentials() {
        let cfg = SandboxManager.SandboxConfig()
        XCTAssertTrue(cfg.allowedEnvironmentKeys.contains("PATH"))
        XCTAssertTrue(cfg.allowedEnvironmentKeys.contains("HOME"))
        XCTAssertTrue(cfg.allowedEnvironmentKeys.contains("PYTORCH_ENABLE_MPS_FALLBACK"))
    }

    func test_violationType_rawValues() {
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.unauthorizedWrite.rawValue, "Escritura no autorizada")
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.networkExposure.rawValue,   "Exposición de red detectada")
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.processRestart.rawValue,    "Reinicio no autorizado")
    }

    func test_processState_rawValues() {
        XCTAssertEqual(SandboxManager.ProcessState.stopped.rawValue,    "Detenido")
        XCTAssertEqual(SandboxManager.ProcessState.running.rawValue,    "Corriendo")
        XCTAssertEqual(SandboxManager.ProcessState.crashed.rawValue,    "Crash detectado")
        XCTAssertEqual(SandboxManager.ProcessState.restricted.rawValue, "Restringido (violación)")
    }

    @MainActor
    func test_isolationStatus_whenStopped_passed() {
        if SandboxManager.shared.processState == .stopped {
            XCTAssertTrue(SandboxManager.shared.isolationStatus.passed)
        }
    }

    func test_sandboxErrors_haveDescriptions() {
        XCTAssertFalse(SandboxError.alreadyRunning.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(SandboxError.scriptNotFound("/path/webui.sh")
            .errorDescription?.contains("/path/webui.sh") ?? false)
        XCTAssertFalse(SandboxError.permissionDenied.errorDescription?.isEmpty ?? true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 05 — IntegrityHashTests
// ─────────────────────────────────────────────────────────────────────────────

final class IntegrityHashTests: XCTestCase {

    func test_sha256_knownVector_abc() {
        XCTAssertEqual("abc".data(using: .utf8)!.sha256Hex,
                       "ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469348423f656b4e4a3")
    }

    func test_sha256_knownVector_empty() {
        XCTAssertEqual(Data().sha256Hex,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func test_sha256_isDeterministic() {
        let data = "SDPipeline Studio".data(using: .utf8)!
        XCTAssertEqual(data.sha256Hex, data.sha256Hex)
    }

    func test_sha256_differentInputs_differentHashes() {
        XCTAssertNotEqual("prompt A".data(using: .utf8)!.sha256Hex,
                          "prompt B".data(using: .utf8)!.sha256Hex)
    }

    func test_sha256_hexLength_is64() {
        XCTAssertEqual("test".data(using: .utf8)!.sha256Hex.count, 64)
    }

    func test_verificationResult_corrupted_storesHashes() {
        if case .corrupted(let s, let a) = IntegrityManager.VerificationResult.corrupted(
            storedHash: "aaa", actualHash: "bbb") {
            XCTAssertEqual(s, "aaa"); XCTAssertEqual(a, "bbb")
        } else { XCTFail("Expected .corrupted") }
    }

    func test_verificationResult_fileNotFound_storesPath() {
        if case .fileNotFound(let p) = IntegrityManager.VerificationResult.fileNotFound(
            path: "/some/path.png") {
            XCTAssertEqual(p, "/some/path.png")
        } else { XCTFail("Expected .fileNotFound") }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 06 — SDRequestTests
// ─────────────────────────────────────────────────────────────────────────────

final class SDRequestTests: XCTestCase {

    func test_defaults() {
        let r = SDRequest(prompt: "t")
        XCTAssertEqual(r.seed,         -1)
        XCTAssertEqual(r.steps,         28)
        XCTAssertEqual(r.sampler_name,  "DPM++ 2M Karras")
        XCTAssertEqual(r.width,         512)
        XCTAssertEqual(r.height,        768)
        XCTAssertFalse(r.enable_hr)
        XCTAssertFalse(r.restore_faces)
        XCTAssertTrue(r.negative_prompt.lowercased().contains("nsfw"))
    }

    func test_customValues_preserved() {
        let r = SDRequest(prompt: "custom", negativePrompt: "neg", seed: 999,
                          steps: 40, cfgScale: 9.5, width: 768, height: 1024,
                          samplerName: "Euler a", batchSize: 2,
                          enableHR: true, hrScale: 2.0, hrSecondPassSteps: 20,
                          denoisingStrength: 0.55, restoreFaces: true)
        XCTAssertEqual(r.prompt,                "custom")
        XCTAssertEqual(r.seed,                  999)
        XCTAssertEqual(r.steps,                 40)
        XCTAssertEqual(r.cfg_scale,             9.5)
        XCTAssertEqual(r.width,                 768)
        XCTAssertEqual(r.height,                1024)
        XCTAssertEqual(r.batch_size,            2)
        XCTAssertTrue(r.enable_hr)
        XCTAssertEqual(r.hr_scale,              2.0)
        XCTAssertEqual(r.hr_second_pass_steps,  20)
        XCTAssertEqual(r.denoising_strength,    0.55)
        XCTAssertTrue(r.restore_faces)
    }

    func test_codableRoundtrip() throws {
        let original = SDRequest(prompt: "editorial fashion", seed: 99, steps: 30, cfgScale: 7.5)
        let decoded  = try JSONDecoder().decode(SDRequest.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.prompt,    original.prompt)
        XCTAssertEqual(decoded.seed,      original.seed)
        XCTAssertEqual(decoded.steps,     original.steps)
        XCTAssertEqual(decoded.cfg_scale, original.cfg_scale)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 07 — SDResponseTests
// ─────────────────────────────────────────────────────────────────────────────

final class SDResponseTests: XCTestCase {

    func decode(_ json: String) throws -> SDProgressResponse {
        try JSONDecoder().decode(SDProgressResponse.self, from: json.data(using: .utf8)!)
    }

    func test_percentDisplay_47() throws {
        XCTAssertEqual(try decode(#"{"progress":0.47,"eta_relative":12.5,"state":null,"current_image":null,"textinfo":null}"#).percentDisplay, "47%")
    }

    func test_etaDisplay_8s() throws {
        XCTAssertEqual(try decode(#"{"progress":0.5,"eta_relative":8.0,"state":null,"current_image":null,"textinfo":null}"#).etaDisplay, "ETA 8s")
    }

    func test_etaDisplay_emptyWhenZero() throws {
        XCTAssertTrue(try decode(#"{"progress":1.0,"eta_relative":0.0,"state":null,"current_image":null,"textinfo":null}"#).etaDisplay.isEmpty)
    }

    func test_sdResponse_decodesImages() throws {
        let r = try JSONDecoder().decode(SDResponse.self,
            from: #"{"images":["base64data1","base64data2"],"parameters":null,"info":null}"#.data(using: .utf8)!)
        XCTAssertEqual(r.images.count, 2)
        XCTAssertEqual(r.images[0], "base64data1")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 08 — PipelineStageTests
// ─────────────────────────────────────────────────────────────────────────────

final class PipelineStageTests: XCTestCase {

    func test_allCases_nonEmptyRawValues() {
        for s in PipelineStage.allCases { XCTAssertFalse(s.rawValue.isEmpty, "\(s) tiene rawValue vacío") }
    }

    func test_done_and_error_exist() {
        XCTAssertTrue(PipelineStage.allCases.contains(.done))
        XCTAssertTrue(PipelineStage.allCases.contains(.error))
    }

    func test_idle_rawValue() {
        XCTAssertEqual(PipelineStage.idle.rawValue, "Idle")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 09 — GenerationSettingsTests
// ─────────────────────────────────────────────────────────────────────────────

final class GenerationSettingsTests: XCTestCase {

    func test_samplersList_notEmpty()               { XCTAssertFalse(GenerationSettings.samplers.isEmpty) }
    func test_samplers_containsDPMPlusPlus()        { XCTAssertTrue(GenerationSettings.samplers.contains("DPM++ 2M Karras")) }
    func test_samplers_containsUniPC()              { XCTAssertTrue(GenerationSettings.samplers.contains("UniPC")) }
    func test_hrUpscalers_containsUltraSharp()      { XCTAssertTrue(GenerationSettings.hrUpscalers.contains("4x-UltraSharp")) }
    func test_defaultBaseURL_isLocalhost()          { XCTAssertTrue(GenerationSettings().sdBaseURL.contains("127.0.0.1")) }
    func test_autoNSFWCheck_enabledByDefault()      { XCTAssertTrue(GenerationSettings().autoRunNSFWCheck) }

    // v2 new fields
    func test_autoRetryOnError_defaultFalse()       { XCTAssertFalse(GenerationSettings().autoRetryOnError) }
    func test_clipSkip_default1()                   { XCTAssertEqual(GenerationSettings().clipSkip, 1) }
    func test_karrasNoise_defaultTrue()             { XCTAssertTrue(GenerationSettings().karrasNoise) }
    func test_autoRunADetailer_defaultFalse()       { XCTAssertFalse(GenerationSettings().autoRunADetailer) }
    func test_autoRunCleanup_defaultFalse()         { XCTAssertFalse(GenerationSettings().autoRunCleanup) }
    func test_img2imgEnabled_defaultFalse()         { XCTAssertFalse(GenerationSettings().img2imgEnabled) }

    func test_makeOverrideSettings_nilWhenDefault() {
        var s = GenerationSettings()
        s.checkpoint = ""; s.vaeUsed = "Automatic"; s.clipSkip = 1
        XCTAssertNil(s.makeOverrideSettings())
    }

    func test_makeOverrideSettings_checkpointIncluded() {
        var s = GenerationSettings(); s.checkpoint = "dreamshaper.safetensors"
        let ov = s.makeOverrideSettings()
        XCTAssertEqual(ov?.sd_model_checkpoint, "dreamshaper.safetensors")
    }

    func test_makeOverrideSettings_clipSkip2() {
        var s = GenerationSettings(); s.clipSkip = 2
        XCTAssertEqual(s.makeOverrideSettings()?.CLIP_stop_at_last_layers, 2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 10 — ADetailerEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class ADetailerEngineTests: XCTestCase {

    func test_apiDict_containsRequiredKeys() {
        let dict = ADetailerUnit().toAPIDict
        for key in ["ad_model","ad_prompt","ad_negative_prompt","ad_confidence",
                    "ad_mask_blur","ad_denoising_strength","ad_inpaint_only_masked",
                    "ad_steps","ad_cfg_scale"] {
            XCTAssertNotNil(dict[key], "API dict debe contener '\(key)'")
        }
    }

    func test_defaultModel_isFaceFull()          { XCTAssertEqual(ADetailerUnit().model, .faceFull) }
    func test_defaultConfidence_is0_3()          { XCTAssertEqual(ADetailerUnit().confidenceThreshold, 0.3, accuracy: 0.001) }
    func test_defaultDenoiseStrength_is0_4()     { XCTAssertEqual(ADetailerUnit().denoiseStrength, 0.40, accuracy: 0.001) }
    func test_allModels_haveDisplayName()        { ADetailerModel.allCases.forEach { XCTAssertFalse($0.displayName.isEmpty) } }

    func test_categoryAssignment() {
        XCTAssertEqual(ADetailerModel.faceFull.category,   .face)
        XCTAssertEqual(ADetailerModel.handYolov8n.category, .hands)
        XCTAssertEqual(ADetailerModel.personSeg.category,  .body)
    }

    @MainActor func test_quickSetupFace_addsOneUnit() {
        let e = ADetailerEngine.shared; e.clearActive()
        e.quickSetupFace()
        XCTAssertEqual(e.activeUnits.count, 1)
        XCTAssertEqual(e.activeUnits.first?.model.category, .face)
    }

    @MainActor func test_quickSetupFaceAndHands_addsTwoUnits() {
        let e = ADetailerEngine.shared; e.clearActive()
        e.quickSetupFaceAndHands()
        XCTAssertEqual(e.activeUnits.count, 2)
    }

    @MainActor func test_addAndRemoveUnit() {
        let e = ADetailerEngine.shared; e.clearActive()
        let unit = ADetailerUnit(model: .faceYolov8s)
        e.addUnit(unit)
        XCTAssertTrue(e.activeUnits.contains(where: { $0.id == unit.id }))
        e.removeUnit(id: unit.id)
        XCTAssertFalse(e.activeUnits.contains(where: { $0.id == unit.id }))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 11 — LoRAEncapsulationTests
// ─────────────────────────────────────────────────────────────────────────────

final class LoRAEncapsulationTests: XCTestCase {

    typealias W = LoRAEncapsulationEngine.LoRAWeight
    typealias C = LoRAEncapsulationEngine.LoRACapsule

    func makeWeight(_ name: String, _ w: Double) -> W { W(loraName: name, weight: w) }

    func makeCapsule(_ name: String = "TestCap") -> C {
        var c = C(name: name, category: .character)
        c.loraWeights = [makeWeight("beautify", 0.8), makeWeight("detail_fix", 0.6)]
        c.triggerWords = ["ohwx woman"]
        return c
    }

    func test_loraWeight_a1111Token_format() {
        XCTAssertEqual(makeWeight("beautify", 0.75).a1111Token, "<lora:beautify:0.75>")
    }

    func test_capsule_fixedMode_containsAllLoRAs() {
        let tokens = makeCapsule().a1111Tokens(intensity: 1.0)
        XCTAssertTrue(tokens.contains("<lora:beautify:"))
        XCTAssertTrue(tokens.contains("<lora:detail_fix:"))
    }

    func test_capsule_linearMode_scalesAtHalf() {
        var c = makeCapsule(); c.intensityMode = .linear
        let half = c.a1111Tokens(intensity: 0.5)
        // beautify(0.8) * 0.5 = 0.40
        XCTAssertTrue(half.contains("0.40"), "Linear 0.5 → peso 0.40")
    }

    func test_capsule_linearMode_zeroIntensity_producesZeroWeights() {
        var c = makeCapsule(); c.intensityMode = .linear
        XCTAssertTrue(c.a1111Tokens(intensity: 0.0).contains("0.00"))
    }

    func test_intensityMode_allCases_present() {
        let modes = C.IntensityMode.allCases
        XCTAssertTrue(modes.contains(.fixed))
        XCTAssertTrue(modes.contains(.linear))
        XCTAssertTrue(modes.contains(.sigmoid))
    }

    @MainActor func test_addCapsule_increasesCount() throws {
        let e = LoRAEncapsulationEngine.shared
        let initial = e.capsules.count
        let c = makeCapsule("Add_\(UUID().uuidString)")
        try e.addCapsule(c)
        XCTAssertEqual(e.capsules.count, initial + 1)
        try? e.deleteCapsule(id: c.id)
    }

    @MainActor func test_deleteCapsule_decreasesCount() throws {
        let e = LoRAEncapsulationEngine.shared
        let c = makeCapsule("Del_\(UUID().uuidString)")
        try e.addCapsule(c)
        let after = e.capsules.count
        try e.deleteCapsule(id: c.id)
        XCTAssertEqual(e.capsules.count, after - 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 12 — JobQueueManagerTests
// ─────────────────────────────────────────────────────────────────────────────

final class JobQueueManagerTests: XCTestCase {

    typealias Job = JobQueueManager.GenerationJob

    func test_defaultStatus_isQueued()   { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).status,   .queued) }
    func test_defaultPriority_isNormal() { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).priority, .normal) }
    func test_defaultAttempts_isZero()   { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).attempts, 0) }
    func test_defaultErrorLog_isEmpty()  { XCTAssertTrue( Job(request: SDRequest(prompt: "t")).errorLog.isEmpty) }
    func test_durationLabel_noStart_returnsDash() { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).durationLabel, "—") }

    func test_uniqueJobIDs() {
        let j1 = Job(request: SDRequest(prompt: "a"))
        let j2 = Job(request: SDRequest(prompt: "b"))
        XCTAssertNotEqual(j1.id, j2.id)
    }

    func test_allStatuses_haveIcons() {
        JobQueueManager.JobStatus.allCases.forEach { XCTAssertFalse($0.icon.isEmpty) }
    }

    func test_allStatuses_haveValidHexColors() {
        JobQueueManager.JobStatus.allCases.forEach {
            XCTAssertTrue($0.hexColor.hasPrefix("#"))
            XCTAssertEqual($0.hexColor.count, 7)
        }
    }

    func test_priorityOrdering_highBeforeNormalBeforeLow() {
        XCTAssertLessThan(JobQueueManager.JobPriority.high,   JobQueueManager.JobPriority.normal)
        XCTAssertLessThan(JobQueueManager.JobPriority.normal, JobQueueManager.JobPriority.low)
    }

    func test_allPriorities_haveLabels() {
        JobQueueManager.JobPriority.allCases.forEach { XCTAssertFalse($0.label.isEmpty) }
    }

    func test_jobSettings_default_autoNSFW_isTrue() {
        XCTAssertTrue(JobQueueManager.JobSettings.default.autoNSFWCheck)
    }

    func test_jobSettings_default_maxRetry_atLeastOne() {
        XCTAssertGreaterThanOrEqual(JobQueueManager.JobSettings.default.maxRetryAttempts, 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 13 — ExportEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class ExportEngineTests: XCTestCase {

    typealias WC = ExportEngine.WatermarkConfig
    typealias EP = ExportEngine.ExportPreset

    func test_watermarkConfig_defaults() {
        let wc = WC()
        XCTAssertEqual(wc.opacity,   0.35, accuracy: 0.001)
        XCTAssertEqual(wc.position,  .bottomRight)
        XCTAssertEqual(wc.fontSize,  18)
        XCTAssertFalse(wc.tiled)
    }

    func test_outputFormat_allCases_nonEmpty() {
        EP.OutputFormat.allCases.forEach { XCTAssertFalse($0.rawValue.isEmpty) }
    }

    func test_exportPreset_codableRoundtrip() throws {
        let preset = EP(name: "OnlyFans HQ", format: .jpeg, quality: 0.92,
                        addWatermark: true, watermarkText: "@creator",
                        maxDimension: 2048, isFavorite: true)
        let decoded = try JSONDecoder().decode(EP.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded.name,         preset.name)
        XCTAssertEqual(decoded.format,       preset.format)
        XCTAssertEqual(decoded.quality,      preset.quality, accuracy: 0.001)
        XCTAssertEqual(decoded.addWatermark, preset.addWatermark)
        XCTAssertEqual(decoded.maxDimension, preset.maxDimension)
        XCTAssertEqual(decoded.isFavorite,   preset.isFavorite)
    }

    func test_exportPreset_uniqueIDs() {
        let p1 = EP(name: "A", format: .jpeg, quality: 0.9, addWatermark: false, watermarkText: "")
        let p2 = EP(name: "B", format: .png,  quality: 1.0, addWatermark: false, watermarkText: "")
        XCTAssertNotEqual(p1.id, p2.id)
    }

    func test_watermarkPosition_allCases_present() {
        let all = WC.Position.allCases
        XCTAssertTrue(all.contains(.topLeft))
        XCTAssertTrue(all.contains(.topRight))
        XCTAssertTrue(all.contains(.bottomLeft))
        XCTAssertTrue(all.contains(.bottomRight))
        XCTAssertTrue(all.contains(.center))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Test Helpers (fallbacks locales — usan la versión real si existe)
// ─────────────────────────────────────────────────────────────────────────────

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02hhx", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting     = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 14 — VaultCryptoEngineTests
// Tests pure CryptoKit primitives used by VaultCryptoEngine — no Keychain required.
// ─────────────────────────────────────────────────────────────────────────────

final class VaultCryptoEngineTests: XCTestCase {

    func test_aesGcm_encryptDecrypt_roundtrip() throws {
        let key       = SymmetricKey(size: .bits256)
        let plaintext = "Hello, Vault! 🔐".data(using: .utf8)!
        let sealed    = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { XCTFail("combined nil"); return }
        let opened    = try AES.GCM.open(.init(combined: combined), using: key)
        XCTAssertEqual(opened, plaintext)
    }

    func test_aesGcm_wrongKey_throws() throws {
        let key1      = SymmetricKey(size: .bits256)
        let key2      = SymmetricKey(size: .bits256)
        let plaintext = "Secret".data(using: .utf8)!
        let sealed    = try AES.GCM.seal(plaintext, using: key1)
        guard let combined = sealed.combined else { return }
        XCTAssertThrowsError(try AES.GCM.open(.init(combined: combined), using: key2))
    }

    func test_hmac_signAndVerify_sameKey() {
        let key  = SymmetricKey(size: .bits256)
        let data = "payload".data(using: .utf8)!
        let mac  = HMAC<SHA256>.authenticationCode(for: data, using: key)
        XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key))
    }

    func test_hmac_wrongKey_fails() {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let data = "payload".data(using: .utf8)!
        let mac  = HMAC<SHA256>.authenticationCode(for: data, using: key1)
        XCTAssertFalse(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key2))
    }

    func test_sha256_knownVector() {
        // SHA256("abc") starts with ba7816bf
        let digest = SHA256.hash(data: "abc".data(using: .utf8)!)
        let hex    = digest.map { String(format: "%02hhx", $0) }.joined()
        XCTAssertTrue(hex.hasPrefix("ba7816bf"))
    }

    func test_sha256_emptyData_knownVector() {
        // SHA256("") = e3b0c44298fc1c149...
        let hex = Data().sha256Hex
        XCTAssertTrue(hex.hasPrefix("e3b0c442"))
    }

    func test_sha256_hexLength_is64() {
        XCTAssertEqual("anything".data(using: .utf8)!.sha256Hex.count, 64)
    }

    func test_sha256_differentData_differentHash() {
        XCTAssertNotEqual(
            "payload1".data(using: .utf8)!.sha256Hex,
            "payload2".data(using: .utf8)!.sha256Hex
        )
    }

    func test_encryptDecrypt_1MB() throws {
        let key    = SymmetricKey(size: .bits256)
        let data   = Data(repeating: 0xAB, count: 1_024 * 1_024)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { XCTFail("combined nil"); return }
        let opened = try AES.GCM.open(.init(combined: combined), using: key)
        XCTAssertEqual(opened, data)
    }

    func test_vaultCryptoEngine_isEncryptionEnabled_default() {
        XCTAssertTrue(VaultCryptoEngine.shared.isEncryptionEnabled)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 15 — SteganographyEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class SteganographyEngineTests: XCTestCase {

    func test_stegPayload_version_notEmpty() {
        let p = SteganographyEngine.StegPayload(
            artistID: "a", assetID: "b", sessionTag: nil,
            timestamp: 0, sha256: "x", checksum: "y"
        )
        XCTAssertFalse(p.version.isEmpty)
        XCTAssertTrue(p.version.hasPrefix("SDPipeline"))
    }

    func test_stegPayload_codableRoundtrip() throws {
        let p = SteganographyEngine.StegPayload(
            artistID: "artist_xyz", assetID: UUID().uuidString,
            sessionTag: "session_01",
            timestamp: Date().timeIntervalSince1970,
            sha256: "abc123", checksum: "chk456"
        )
        let decoded = try JSONDecoder().decode(
            SteganographyEngine.StegPayload.self,
            from: JSONEncoder().encode(p)
        )
        XCTAssertEqual(decoded.artistID,   p.artistID)
        XCTAssertEqual(decoded.assetID,    p.assetID)
        XCTAssertEqual(decoded.sessionTag, p.sessionTag)
        XCTAssertEqual(decoded.sha256,     p.sha256)
    }

    func test_artistID_nonEmpty() {
        XCTAssertFalse(SteganographyEngine.shared.config.artistID.isEmpty)
    }

    func test_artistID_persistedAcrossCalls() {
        let id1 = SteganographyEngine.shared.config.artistID
        let id2 = SteganographyEngine.shared.config.artistID
        XCTAssertEqual(id1, id2)
    }

    func test_hmacKey_256bits() {
        XCTAssertEqual(SteganographyEngine.shared.config.hmacKey.bitCount, 256)
    }

    func test_channels_defaultRGB() {
        XCTAssertEqual(SteganographyEngine.shared.config.channels, [0, 1, 2])
    }

    func test_bitsPerChannel_default1() {
        XCTAssertEqual(SteganographyEngine.shared.config.bitsPerChannel, 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 16 — PromptSafetyFilter_v2Tests
// Covers the public API surface: validate(json:), validatePrompt(positive:negative:),
// and FilterResult computed properties.
// ─────────────────────────────────────────────────────────────────────────────

final class PromptSafetyFilter_v2Tests: XCTestCase {

    // Helper matching real API — FIX: the standalone validate(_:String) doesn't exist;
    // the real methods are validatePrompt(positive:negative:) and validateJSON(_:)
    func validate(_ prompt: String) -> PromptSafetyFilter.FilterResult {
        PromptSafetyFilter.validatePrompt(positive: prompt, negative: "")
    }

    func test_cleanPrompt_isAllowed() {
        guard case .allowed = validate("editorial portrait, studio lighting") else {
            XCTFail("Clean prompt should be .allowed"); return
        }
    }

    func test_loli_isBlocked() {
        guard case .blocked = validate("loli anime art") else {
            XCTFail("loli must be blocked"); return
        }
    }

    func test_childTerm_isBlocked() {
        guard case .blocked = validate("child model photoshoot") else {
            XCTFail("child term must be blocked"); return
        }
    }

    func test_nonConsent_isBlocked() {
        guard case .blocked = validate("non-consent fantasy") else {
            XCTFail("non-consent must be blocked"); return
        }
    }

    func test_incest_isBlocked() {
        guard case .blocked = validate("incest roleplay") else {
            XCTFail("incest must be blocked"); return
        }
    }

    func test_emptyPrompt_isAllowed() {
        guard case .allowed = validate("") else {
            XCTFail("Empty prompt must be allowed"); return
        }
    }

    func test_caseInsensitive_loli_blocked() {
        guard case .blocked = validate("LOLI character") else {
            XCTFail("Block must be case-insensitive"); return
        }
    }

    func test_softFlag_barelyLegal() {
        let r = validate("barely legal model, artistic nude")
        // Could be .flagged or .blocked — must not be .allowed
        XCTAssertFalse(r.isAllowed, "barely legal must not pass without warning")
    }

    func test_filterResult_isAllowed_computed() {
        XCTAssertTrue(PromptSafetyFilter.FilterResult.allowed.isAllowed)
        XCTAssertFalse(PromptSafetyFilter.FilterResult.allowed.isBlocked)
        XCTAssertFalse(PromptSafetyFilter.FilterResult.allowed.isFlagged)
    }

    func test_filterResult_isBlocked_computed() {
        let r = PromptSafetyFilter.FilterResult.blocked(reason: "test", matchedTerms: ["x"])
        XCTAssertTrue(r.isBlocked)
        XCTAssertFalse(r.isAllowed)
        XCTAssertFalse(r.isFlagged)
    }

    func test_filterResult_isFlagged_computed() {
        let r = PromptSafetyFilter.FilterResult.flagged(warnings: ["w"])
        XCTAssertTrue(r.isFlagged)
        XCTAssertFalse(r.isBlocked)
        XCTAssertFalse(r.isAllowed)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 17 — NSFWDetectorTests
// ─────────────────────────────────────────────────────────────────────────────

final class NSFWDetectorTests: XCTestCase {

    func test_nsfwLevel_ordering() {
        XCTAssertLessThan(NSFWLevel.safe,     NSFWLevel.mild)
        XCTAssertLessThan(NSFWLevel.mild,     NSFWLevel.moderate)
        XCTAssertLessThan(NSFWLevel.moderate, NSFWLevel.explicit)
    }

    func test_nsfwLevel_rawValues_sequential() {
        XCTAssertEqual(NSFWLevel.safe.rawValue,     0)
        XCTAssertEqual(NSFWLevel.mild.rawValue,     1)
        XCTAssertEqual(NSFWLevel.moderate.rawValue, 2)
        XCTAssertEqual(NSFWLevel.explicit.rawValue, 3)
    }

    func test_allLevels_haveLabels() {
        NSFWLevel.allCases.forEach { XCTAssertFalse($0.label.isEmpty) }
    }

    func test_allLevels_haveIcons() {
        NSFWLevel.allCases.forEach { XCTAssertFalse($0.icon.isEmpty) }
    }

    func test_nsfwPolicy_defaults_sensible() {
        let p = NSFWPolicy()
        // thresholdForFlag must be ≤ thresholdForQuarantine
        XCTAssertLessThanOrEqual(p.thresholdForFlag, p.thresholdForQuarantine)
    }

    func test_nsfwDetectionResult_codable() throws {
        let r       = NSFWDetectionResult(promptLevel: .moderate, imageLevel: nil,
                                          finalLevel: .moderate, triggerWords: ["nsfw"],
                                          action: .flag, prompt: "test", imagePath: nil)
        let decoded = try JSONDecoder().decode(
            NSFWDetectionResult.self, from: JSONEncoder().encode(r)
        )
        XCTAssertEqual(decoded.finalLevel,  r.finalLevel)
        XCTAssertEqual(decoded.promptLevel, r.promptLevel)
        XCTAssertEqual(decoded.action,      r.action)
    }

    func test_nsfwDetectionResult_uniqueIDs() {
        let r1 = NSFWDetectionResult(promptLevel: .safe, imageLevel: nil,
                                     finalLevel: .safe, triggerWords: [],
                                     action: .none, prompt: "a", imagePath: nil)
        let r2 = NSFWDetectionResult(promptLevel: .mild, imageLevel: nil,
                                     finalLevel: .mild, triggerWords: [],
                                     action: .none, prompt: "b", imagePath: nil)
        XCTAssertNotEqual(r1.id, r2.id)
    }

    @MainActor func test_analyzePrompt_safeContent_returnsSafe() {
        let (level, _) = NSFWDetector.shared.analyzePrompt(
            "editorial portrait, studio lighting, elegant dress"
        )
        XCTAssertLessThanOrEqual(level, NSFWLevel.mild)
    }

    @MainActor func test_logResultZK_doesNotCrash() {
        // FIX v2: logResultZK was missing — verify it exists and runs without crash
        let r = NSFWDetectionResult(promptLevel: .safe, imageLevel: nil,
                                    finalLevel: .safe, triggerWords: [],
                                    action: .none, prompt: "safe prompt", imagePath: nil)
        NSFWDetector.shared.logResultZK(r)   // must not crash
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 18 — Img2ImgRequestTests
// ─────────────────────────────────────────────────────────────────────────────

final class Img2ImgRequestTests: XCTestCase {

    func test_init_setsBase64Image() {
        let req = SDImg2ImgRequest(base64Image: "base64data", prompt: "refine")
        XCTAssertEqual(req.init_images.count, 1)
        XCTAssertEqual(req.init_images[0], "base64data")
    }

    func test_defaultResizeMode_isScaleToFit() {
        let req = SDImg2ImgRequest(base64Image: "d", prompt: "p")
        XCTAssertEqual(req.resize_mode, Img2ImgResizeMode.scaleToFit.rawValue)
    }

    func test_maskNilByDefault() {
        XCTAssertNil(SDImg2ImgRequest(base64Image: "d", prompt: "p").mask)
    }

    func test_maskSetWhenProvided() {
        let req = SDImg2ImgRequest(base64Image: "d", prompt: "p", mask: "maskdata")
        XCTAssertEqual(req.mask, "maskdata")
    }

    func test_img2imgResizeModes_allHaveLabels() {
        Img2ImgResizeMode.allCases.forEach { XCTAssertFalse($0.label.isEmpty) }
    }

    func test_img2imgResizeModes_rawValuesSequential() {
        XCTAssertEqual(Img2ImgResizeMode.justResize.rawValue,    0)
        XCTAssertEqual(Img2ImgResizeMode.cropAndResize.rawValue, 1)
        XCTAssertEqual(Img2ImgResizeMode.scaleToFit.rawValue,    2)
        XCTAssertEqual(Img2ImgResizeMode.latentUpscale.rawValue, 3)
    }

    func test_inpaintFill_rawValuesSequential() {
        XCTAssertEqual(InpaintFill.fill.rawValue,          0)
        XCTAssertEqual(InpaintFill.original.rawValue,      1)
        XCTAssertEqual(InpaintFill.latentNoise.rawValue,   2)
        XCTAssertEqual(InpaintFill.latentNothing.rawValue, 3)
    }

    func test_inpaintFill_defaultIsLatentNoise() {
        let req = SDImg2ImgRequest(base64Image: "d", prompt: "p")
        XCTAssertEqual(req.inpainting_fill, InpaintFill.latentNoise.rawValue)
    }

    func test_codableRoundtrip() throws {
        let req = SDImg2ImgRequest(
            base64Image: "imgdata", prompt: "test",
            denoisingStrength: 0.6, resizeMode: .cropAndResize
        )
        let decoded = try JSONDecoder().decode(
            SDImg2ImgRequest.self, from: JSONEncoder().encode(req)
        )
        XCTAssertEqual(decoded.prompt,             req.prompt)
        XCTAssertEqual(decoded.denoising_strength, 0.6, accuracy: 0.001)
        XCTAssertEqual(decoded.resize_mode,        Img2ImgResizeMode.cropAndResize.rawValue)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 19 — ControlNetUnitTests
// Tests against ControlNetUnit defined in ControlNetEngine.swift (the canonical type).
// ControlNetUnit uses ControlNetModule enum (module), ControlMode enum (controlMode),
// ResizeMode enum (resizeMode), and toAPIDict (not scriptPayload).
// ─────────────────────────────────────────────────────────────────────────────

final class ControlNetUnitTests: XCTestCase {

    func test_defaultUnit_isEnabled()      { XCTAssertTrue(ControlNetUnit().enabled) }
    func test_defaultUnit_pixelPerfect()   { XCTAssertTrue(ControlNetUnit().pixelPerfect) }
    func test_defaultUnit_weightIs1()      { XCTAssertEqual(ControlNetUnit().weight, 1.0, accuracy: 0.001) }
    func test_defaultUnit_imageNil()       { XCTAssertNil(ControlNetUnit().imageBase64) }
    func test_defaultUnit_moduleIsCanny()  { XCTAssertEqual(ControlNetUnit().module, .canny) }
    func test_defaultUnit_modelEmpty()     { XCTAssertTrue(ControlNetUnit().model.isEmpty) }

    func test_toAPIDict_requiredKeys() {
        // Real ControlNetUnit uses toAPIDict (not scriptPayload)
        let dict = ControlNetUnit().toAPIDict
        for key in ["enabled","module","model","weight","guidance_start","guidance_end","pixel_perfect"] {
            XCTAssertNotNil(dict[key], "Missing key: \(key)")
        }
    }

    func test_toAPIDict_imageAbsentWhenNil() {
        XCTAssertNil(ControlNetUnit().toAPIDict["image"])
    }

    func test_toAPIDict_imageIncludedWhenSet() {
        var unit = ControlNetUnit(); unit.imageBase64 = "testimg"
        XCTAssertEqual(unit.toAPIDict["image"] as? String, "testimg")
    }

    func test_allModules_haveRawValues() {
        ControlNetModule.allCases.forEach { XCTAssertFalse($0.rawValue.isEmpty) }
    }

    func test_allControlModes_haveRawValues() {
        ControlNetUnit.ControlMode.allCases.forEach { XCTAssertFalse($0.rawValue.isEmpty) }
    }

    func test_allResizeModes_haveRawValues() {
        ControlNetUnit.ResizeMode.allCases.forEach { XCTAssertFalse($0.rawValue.isEmpty) }
    }

    func test_codableRoundtrip() throws {
        var unit = ControlNetUnit()
        unit.model  = "control_v11p_sd15_canny"
        unit.module = .canny
        unit.weight = 0.85
        let decoded = try JSONDecoder().decode(ControlNetUnit.self, from: JSONEncoder().encode(unit))
        XCTAssertEqual(decoded.id,     unit.id)
        XCTAssertEqual(decoded.model,  "control_v11p_sd15_canny")
        XCTAssertEqual(decoded.module, .canny)
        XCTAssertEqual(decoded.weight, 0.85, accuracy: 0.001)
    }

    func test_uniqueIDs() {
        XCTAssertNotEqual(ControlNetUnit().id, ControlNetUnit().id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 20 — PromptDatabaseTests
// FIX: tests use the real API (search(query:), saveFromPipeline, applyFilter)
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class PromptDatabaseTests: XCTestCase {

    func test_search_emptyQuery_returnsAll() {
        let db      = PromptDatabase.shared
        let initial = db.entries.count
        let results = db.search(query: "")
        XCTAssertEqual(results.count, initial)
    }

    func test_search_nonExistentQuery_returnsEmpty() {
        let results = PromptDatabase.shared.search(
            query: "xkq9zzz_unlikely_token_\(UUID().uuidString)"
        )
        XCTAssertTrue(results.isEmpty)
    }

    func test_saveFromPipeline_addsEntry() {
        let db      = PromptDatabase.shared
        let initial = db.entries.count
        _ = db.saveFromPipeline(
            positive: "test_suite20_\(UUID().uuidString)",
            negative: "ugly",
            checkpoint: "test_model",
            title: "UnitTest"
        )
        XCTAssertEqual(db.entries.count, initial + 1)
    }

    func test_save_then_search_findsEntry() {
        let db     = PromptDatabase.shared
        let marker = "xtestsearch_\(UUID().uuidString)"
        let entry  = db.saveFromPipeline(positive: marker, title: "SearchTest")
        let found  = db.search(query: marker)
        XCTAssertTrue(found.contains(where: { $0.id == entry.id }))
        db.delete(entry)
    }

    func test_delete_removesEntry() {
        let db    = PromptDatabase.shared
        let entry = db.saveFromPipeline(positive: "delete_test_\(UUID().uuidString)")
        let before = db.entries.count
        db.delete(entry)
        XCTAssertEqual(db.entries.count, before - 1)
    }

    func test_updateRating_changesRating() {
        let db    = PromptDatabase.shared
        var entry = db.saveFromPipeline(positive: "rating_test_\(UUID().uuidString)")
        db.updateRating(entry, rating: 4)
        let updated = db.entries.first(where: { $0.id == entry.id })
        XCTAssertEqual(updated?.rating, 4)
        db.delete(entry)
    }

    func test_toggleFavorite_changes() {
        let db    = PromptDatabase.shared
        let entry = db.saveFromPipeline(positive: "fav_test_\(UUID().uuidString)")
        XCTAssertFalse(entry.isFavorite)
        db.toggleFavorite(entry)
        let updated = db.entries.first(where: { $0.id == entry.id })
        XCTAssertTrue(updated?.isFavorite ?? false)
        db.delete(entry)
    }

    func test_applyFilter_ratingFilter() {
        let db     = PromptDatabase.shared
        let p1     = db.saveFromPipeline(positive: "r5_\(UUID())")
        let p2     = db.saveFromPipeline(positive: "r1_\(UUID())")
        db.updateRating(p1, rating: 5)
        db.updateRating(p2, rating: 1)
        let f      = PromptFilter(minRating: 4)
        let result = db.applyFilter(f, to: [p1, p2])
        XCTAssertTrue(result.contains(where: { $0.id == p1.id }))
        XCTAssertFalse(result.contains(where: { $0.id == p2.id }))
        db.delete(p1); db.delete(p2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Test Helpers
// ─────────────────────────────────────────────────────────────────────────────

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02hhx", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting     = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

#endif
