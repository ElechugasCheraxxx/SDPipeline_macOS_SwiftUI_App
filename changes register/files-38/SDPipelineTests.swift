import XCTest
import CryptoKit
import Foundation
@testable import SDPipeline   // Ajusta al nombre exacto de tu target principal

// MARK: - SDPipelineTests  ✅ ROADMAP 100%
//
// 13 suites · 90+ assertions
//
// SUITE 01  PromptBuilderTests          — schema, flat, dedup, meta-keys, boosters
// SUITE 02  PromptSafetyFilterTests     — hard blocks, soft flags, validateJSON, mutualExcl.
// SUITE 03  SidecarJSONTests            — encode/decode, save/load, hrFix nil/set
// SUITE 04  SandboxManagerTests         — config defaults, violations, processState
// SUITE 05  IntegrityHashTests          — SHA-256 vectores conocidos, determinismo
// SUITE 06  SDRequestTests              — defaults, custom values, Codable roundtrip
// SUITE 07  SDResponseTests             — percentDisplay, etaDisplay, images parsing
// SUITE 08  PipelineStageTests          — rawValues no vacíos, done/error presentes
// SUITE 09  GenerationSettingsTests     — samplers, upscalers, NSFW default, localhost
// SUITE 10  ADetailerEngineTests        — unit API dict keys, models, quickSetup
// SUITE 11  LoRAEncapsulationTests      — capsule tokens, intensity modes, CRUD
// SUITE 12  JobQueueManagerTests        — GenerationJob init, status, priority sort
// SUITE 13  ExportEngineTests           — WatermarkConfig defaults, ExportPreset Codable

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
    func test_hrUpscalers_containsUltraSharp()      { XCTAssertTrue(GenerationSettings.hrUpscalers.contains("4x-UltraSharp")) }
    func test_defaultBaseURL_isLocalhost()          { XCTAssertTrue(GenerationSettings().sdBaseURL.contains("127.0.0.1")) }
    func test_autoNSFWCheck_enabledByDefault()      { XCTAssertTrue(GenerationSettings().autoRunNSFWCheck) }
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
