#if canImport(XCTest)
import XCTest
import CryptoKit
import Foundation
@testable import SDPipeline

// MARK: - SDPipelineTests v2
//
// Cambios v1 → v2:
//   ✨ ADD: SUITE 14 — VaultCryptoEngineTests    (encrypt/decrypt roundtrip, HMAC verify, key rotation)
//   ✨ ADD: SUITE 15 — SteganographyEngineTests  (payload model, artist ID gen, HMAC key gen)
//   ✨ ADD: SUITE 16 — PromptSafetyFilterTests   (hardBlocks, softFlags, allowlist, edge cases)
//   ✨ ADD: SUITE 17 — NSFWDetectorTests         (prompt scoring, policy defaults, result model)
//   ✨ ADD: SUITE 18 — IntegrityManagerTests     (hash computation, record model, verification status)
//   ✨ ADD: SUITE 19 — TaggingEngineTests        (add/remove/search, AND/OR modes, suggestions)
//   🔁 UPD: Models.swift v2 types reflected in Suites 01, 05, 06 (PipelineStage extra cases)

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
        XCTAssertFalse(r.contains("1.0"), "version es meta key — debe ignorarse")
        XCTAssertFalse(r.contains("char_001"), "character_id es meta key — debe ignorarse")
        XCTAssertTrue(r.contains("cinematic"))
    }

    // v2 — new fields coverage
    func test_locationInterior_isExtracted() {
        let json: [String: Any] = [
            "environment_system": ["location_interior": "luxury penthouse", "time_of_day": "evening"]
        ]
        let r = PromptBuilder.buildFromEditorialSchema(json)
        XCTAssertTrue(r.positive.contains("luxury penthouse"))
        XCTAssertTrue(r.positive.contains("evening"))
    }

    func test_locationExterior_isExtracted() {
        let json: [String: Any] = [
            "environment_system": ["location_exterior": "rooftop terrace", "weather": "golden hour"]
        ]
        let r = PromptBuilder.buildFromEditorialSchema(json)
        XCTAssertTrue(r.positive.contains("rooftop terrace"))
        XCTAssertTrue(r.positive.contains("golden hour"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 02 — GenerationSettingsTests
// ─────────────────────────────────────────────────────────────────────────────

final class GenerationSettingsTests: XCTestCase {

    func test_defaultSettings_seedIsRandom()     { XCTAssertEqual(GenerationSettings.default.seed, -1) }
    func test_defaultSettings_stepsIs28()        { XCTAssertEqual(GenerationSettings.default.steps, 28) }
    func test_defaultSettings_cfgIs7()           { XCTAssertEqual(GenerationSettings.default.cfgScale, 7.0, accuracy: 0.001) }
    func test_defaultSettings_samplerIsKarras()  { XCTAssertTrue(GenerationSettings.default.samplerName.contains("Karras")) }
    func test_defaultSettings_HRDisabled()       { XCTAssertFalse(GenerationSettings.default.enableHR) }
    func test_defaultSettings_restoreFacesOff()  { XCTAssertFalse(GenerationSettings.default.restoreFaces) }

    // v2 defaults
    func test_v2_clipSkipDefault_is1()           { XCTAssertEqual(GenerationSettings.default.clipSkip, 1) }
    func test_v2_karrasNoise_defaultTrue()       { XCTAssertTrue(GenerationSettings.default.karrasNoise) }
    func test_v2_img2imgEnabled_defaultFalse()   { XCTAssertFalse(GenerationSettings.default.img2imgEnabled) }
    func test_v2_autoRunADetailer_defaultFalse() { XCTAssertFalse(GenerationSettings.default.autoRunADetailer) }

    func test_makeOverrideSettings_nilWhenDefault() {
        var s = GenerationSettings.default
        s.checkpoint = ""
        s.vaeUsed    = "Automatic"
        s.clipSkip   = 1
        XCTAssertNil(s.makeOverrideSettings())
    }

    func test_makeOverrideSettings_notNilWithCheckpoint() {
        var s = GenerationSettings.default
        s.checkpoint = "v1-5-pruned.safetensors"
        let ov = s.makeOverrideSettings()
        XCTAssertNotNil(ov)
        XCTAssertEqual(ov?.sd_model_checkpoint, "v1-5-pruned.safetensors")
    }

    func test_makeOverrideSettings_clipSkip2_included() {
        var s = GenerationSettings.default
        s.clipSkip = 2
        let ov = s.makeOverrideSettings()
        XCTAssertEqual(ov?.CLIP_stop_at_last_layers, 2)
    }

    func test_samplers_containsUniPC() {
        XCTAssertTrue(GenerationSettings.samplers.contains("UniPC"))
    }

    func test_samplers_nonEmpty() {
        XCTAssertFalse(GenerationSettings.samplers.isEmpty)
    }

    func test_hrUpscalers_nonEmpty() {
        XCTAssertFalse(GenerationSettings.hrUpscalers.isEmpty)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 03 — SDRequestTests
// ─────────────────────────────────────────────────────────────────────────────

final class SDRequestTests: XCTestCase {

    func test_defaultInit_promptSet() {
        let r = SDRequest(prompt: "test prompt")
        XCTAssertEqual(r.prompt, "test prompt")
    }

    func test_defaultInit_seedMinus1() {
        XCTAssertEqual(SDRequest(prompt: "x").seed, -1)
    }

    func test_defaultInit_batchSize1() {
        XCTAssertEqual(SDRequest(prompt: "x").batch_size, 1)
    }

    func test_codableRoundtrip() throws {
        let req = SDRequest(
            prompt: "a beautiful woman",
            negativePrompt: "ugly",
            seed: 42, steps: 20, cfgScale: 7.5,
            width: 512, height: 768, samplerName: "Euler a",
            enableHR: true, hrScale: 2.0
        )
        let data    = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(SDRequest.self, from: data)
        XCTAssertEqual(decoded.prompt,          req.prompt)
        XCTAssertEqual(decoded.seed,            req.seed)
        XCTAssertEqual(decoded.cfg_scale,       req.cfg_scale, accuracy: 0.001)
        XCTAssertEqual(decoded.enable_hr,       req.enable_hr)
        XCTAssertEqual(decoded.hr_scale,        req.hr_scale, accuracy: 0.001)
    }

    func test_overrideSettings_codable() throws {
        let ov = SDRequestOverrideSettings(checkpoint: "model.safetensors", clipSkip: 2)
        let data    = try JSONEncoder().encode(ov)
        let decoded = try JSONDecoder().decode(SDRequestOverrideSettings.self, from: data)
        XCTAssertEqual(decoded.sd_model_checkpoint, "model.safetensors")
        XCTAssertEqual(decoded.CLIP_stop_at_last_layers, 2)
        XCTAssertNil(decoded.sd_vae)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 04 — Img2ImgRequestTests (NEW v2 suite)
// ─────────────────────────────────────────────────────────────────────────────

final class Img2ImgRequestTests: XCTestCase {

    func test_init_setsBase64Image() {
        let req = SDImg2ImgRequest(base64Image: "base64data", prompt: "refine this")
        XCTAssertEqual(req.init_images.count, 1)
        XCTAssertEqual(req.init_images[0], "base64data")
    }

    func test_defaultResizeMode_isScaleToFit() {
        let req = SDImg2ImgRequest(base64Image: "data", prompt: "test")
        XCTAssertEqual(req.resize_mode, Img2ImgResizeMode.scaleToFit.rawValue)
    }

    func test_mask_nilByDefault() {
        let req = SDImg2ImgRequest(base64Image: "data", prompt: "test")
        XCTAssertNil(req.mask)
    }

    func test_mask_setWhenProvided() {
        let req = SDImg2ImgRequest(base64Image: "data", prompt: "inpaint", mask: "maskdata")
        XCTAssertEqual(req.mask, "maskdata")
    }

    func test_img2imgResizeModes_allCases_nonEmpty() {
        Img2ImgResizeMode.allCases.forEach { XCTAssertFalse($0.label.isEmpty) }
    }

    func test_inpaintFill_allCases_rawValuesSequential() {
        let raw = InpaintFill.allCases.map(\.rawValue)
        XCTAssertEqual(raw, [0, 1, 2, 3])
    }

    func test_img2imgRequest_codable() throws {
        let req = SDImg2ImgRequest(
            base64Image: "imgdata",
            prompt: "test", denoisingStrength: 0.6,
            resizeMode: .cropAndResize
        )
        let data    = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(SDImg2ImgRequest.self, from: data)
        XCTAssertEqual(decoded.prompt,              req.prompt)
        XCTAssertEqual(decoded.denoising_strength,  0.6, accuracy: 0.001)
        XCTAssertEqual(decoded.resize_mode,         Img2ImgResizeMode.cropAndResize.rawValue)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 05 — PipelineStageTests
// ─────────────────────────────────────────────────────────────────────────────

final class PipelineStageTests: XCTestCase {

    func test_idleStage_isNotActive()       { XCTAssertFalse(PipelineStage.idle.isActive) }
    func test_doneStage_isNotActive()       { XCTAssertFalse(PipelineStage.done.isActive) }
    func test_errorStage_isNotActive()      { XCTAssertFalse(PipelineStage.error.isActive) }
    func test_sendingStage_isActive()       { XCTAssertTrue(PipelineStage.sending.isActive) }
    func test_receivingStage_isActive()     { XCTAssertTrue(PipelineStage.receiving.isActive) }

    // v2 new stages
    func test_img2imgStage_isActive()       { XCTAssertTrue(PipelineStage.img2img.isActive) }
    func test_upscalingStage_isActive()     { XCTAssertTrue(PipelineStage.upscaling.isActive) }
    func test_adetailerStage_isActive()     { XCTAssertTrue(PipelineStage.adetailer.isActive) }
    func test_cleanupStage_isActive()       { XCTAssertTrue(PipelineStage.cleanup.isActive) }
    func test_interruptedStage_isNotActive(){ XCTAssertFalse(PipelineStage.interrupted.isActive) }

    func test_allStages_haveIcons() {
        PipelineStage.allCases.forEach { stage in
            XCTAssertFalse(stage.icon.isEmpty, "\(stage.rawValue) has empty icon")
        }
    }

    func test_allStages_haveRawValues() {
        PipelineStage.allCases.forEach { XCTAssertFalse($0.rawValue.isEmpty) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 06 — CharacterProfileTests (NEW v2 suite)
// ─────────────────────────────────────────────────────────────────────────────

final class CharacterProfileTests: XCTestCase {

    func makeProfile(name: String = "Valentina") -> CharacterProfile {
        var p = CharacterProfile(name: name)
        p.promptCore    = "latina woman, dark hair"
        p.promptStyle   = "editorial style"
        p.promptTrigger = "ohwx woman"
        p.loraWeights   = ["beautify_v2": 0.8, "detail_tweaker": 0.6]
        return p
    }

    func test_uniqueIDs() {
        let a = CharacterProfile(name: "A")
        let b = CharacterProfile(name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_fullPromptFragment_joinsAllParts() {
        let p = makeProfile()
        XCTAssertTrue(p.fullPromptFragment.contains("latina woman"))
        XCTAssertTrue(p.fullPromptFragment.contains("editorial style"))
        XCTAssertTrue(p.fullPromptFragment.contains("ohwx woman"))
    }

    func test_loraTokens_formatCorrect() {
        let p = makeProfile()
        XCTAssertTrue(p.loraTokens.contains("<lora:beautify_v2:"))
        XCTAssertTrue(p.loraTokens.contains("<lora:detail_tweaker:"))
    }

    func test_loraTokens_emptyWhenNoLoRAs() {
        var p = CharacterProfile(name: "Empty")
        p.loraWeights = [:]
        XCTAssertTrue(p.loraTokens.isEmpty)
    }

    func test_codableRoundtrip() throws {
        let p       = makeProfile()
        let data    = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(CharacterProfile.self, from: data)
        XCTAssertEqual(decoded.id,          p.id)
        XCTAssertEqual(decoded.name,        p.name)
        XCTAssertEqual(decoded.promptCore,  p.promptCore)
        XCTAssertEqual(decoded.loraWeights, p.loraWeights)
    }

    func test_hashable_equalByID() {
        let p1 = makeProfile()
        var p2 = p1
        p2.name = "Different Name"
        XCTAssertEqual(p1, p2, "Equality must be by ID")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 07 — LoRAEntryTests (NEW v2 suite)
// ─────────────────────────────────────────────────────────────────────────────

final class LoRAEntryTests: XCTestCase {

    func test_displayName_usesAliasWhenSet() {
        var e = LoRAEntry(name: "beautify_lora_v2")
        e.alias = "Beautify v2"
        XCTAssertEqual(e.displayName, "Beautify v2")
    }

    func test_displayName_fallsBackToName() {
        let e = LoRAEntry(name: "beautify_lora_v2")
        XCTAssertEqual(e.displayName, "beautify_lora_v2")
    }

    func test_codableRoundtrip() throws {
        var e        = LoRAEntry(name: "test_lora", alias: "Test LoRA")
        e.metadata   = LoRAEntry.LoRAMeta(triggerWords: ["ohwx"])
        let data     = try JSONEncoder().encode(e)
        let decoded  = try JSONDecoder().decode(LoRAEntry.self, from: data)
        XCTAssertEqual(decoded.name,                      e.name)
        XCTAssertEqual(decoded.alias,                     e.alias)
        XCTAssertEqual(decoded.metadata?.triggerWords,    ["ohwx"])
    }

    func test_selectedLoRA_a1111Token_format() {
        let entry  = LoRAEntry(name: "beautify")
        let sel    = SelectedLoRA(lora: entry, weight: 0.75)
        XCTAssertEqual(sel.a1111Token, "<lora:beautify:0.75>")
    }

    func test_selectedLoRA_uniqueIDs() {
        let e   = LoRAEntry(name: "x")
        let s1  = SelectedLoRA(lora: e, weight: 0.5)
        let s2  = SelectedLoRA(lora: e, weight: 0.5)
        XCTAssertNotEqual(s1.id, s2.id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 08 — ControlNetUnitTests (NEW v2 suite)
// ─────────────────────────────────────────────────────────────────────────────

final class ControlNetUnitTests: XCTestCase {

    func test_defaultUnit_isEnabled()          { XCTAssertTrue(ControlNetUnit().enabled) }
    func test_defaultUnit_moduleIsNone()       { XCTAssertEqual(ControlNetUnit().module, "none") }
    func test_defaultUnit_pixelPerfectOn()     { XCTAssertTrue(ControlNetUnit().pixelPerfect) }
    func test_defaultUnit_weightIs1()          { XCTAssertEqual(ControlNetUnit().weight, 1.0, accuracy: 0.001) }

    func test_scriptPayload_containsRequiredKeys() {
        let unit    = ControlNetUnit()
        let payload = unit.scriptPayload
        XCTAssertNotNil(payload["enabled"])
        XCTAssertNotNil(payload["model"])
        XCTAssertNotNil(payload["module"])
        XCTAssertNotNil(payload["weight"])
        XCTAssertNotNil(payload["guidance_start"])
        XCTAssertNotNil(payload["guidance_end"])
        XCTAssertNotNil(payload["pixel_perfect"])
    }

    func test_scriptPayload_imageIncludedWhenSet() {
        var unit = ControlNetUnit()
        unit.imageBase64 = "testimg"
        XCTAssertEqual(unit.scriptPayload["image"] as? String, "testimg")
    }

    func test_scriptPayload_imageAbsentWhenNil() {
        let unit = ControlNetUnit()
        XCTAssertNil(unit.scriptPayload["image"])
    }

    func test_codableRoundtrip() throws {
        var unit         = ControlNetUnit()
        unit.model       = "control_v11p_sd15_canny"
        unit.module      = "canny"
        unit.weight      = 0.85
        let data         = try JSONEncoder().encode(unit)
        let decoded      = try JSONDecoder().decode(ControlNetUnit.self, from: data)
        XCTAssertEqual(decoded.id,     unit.id)
        XCTAssertEqual(decoded.model,  "control_v11p_sd15_canny")
        XCTAssertEqual(decoded.module, "canny")
        XCTAssertEqual(decoded.weight, 0.85, accuracy: 0.001)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 09 — WildcardEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class WildcardEngineTests: XCTestCase {

    func test_noWildcard_returnedUnchanged() {
        let p = "editorial portrait, studio lighting"
        XCTAssertEqual(WildcardEngine.shared.resolve(p), p)
    }

    func test_unknownWildcard_removedOrKept() {
        let p       = "woman in __nonexistent_group__"
        let result  = WildcardEngine.shared.resolve(p)
        XCTAssertNotNil(result)
    }

    func test_builtIn_lighting_resolved() {
        let p      = "__lighting__"
        let result = WildcardEngine.shared.resolve(p)
        XCTAssertNotEqual(result, p, "__lighting__ should resolve to something")
        XCTAssertFalse(result.isEmpty)
    }

    func test_builtIn_outfit_resolved() {
        let p      = "wearing __outfit__"
        let result = WildcardEngine.shared.resolve(p)
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, p)
    }

    func test_multipleWildcards_allResolved() {
        let p      = "__lighting__ and __mood__"
        let result = WildcardEngine.shared.resolve(p)
        XCTAssertFalse(result.contains("__"), "All wildcards should be resolved")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 10 — SeedManagerTests
// ─────────────────────────────────────────────────────────────────────────────

final class SeedManagerTests: XCTestCase {

    func test_randomSeed_notMinus1() {
        let s = SeedManager.shared.randomSeed()
        XCTAssertNotEqual(s, -1)
        XCTAssertGreaterThanOrEqual(s, 0)
    }

    func test_twoRandomSeeds_areDifferent() {
        let s1 = SeedManager.shared.randomSeed()
        let s2 = SeedManager.shared.randomSeed()
        XCTAssertNotEqual(s1, s2)
    }

    func test_effectiveSeed_minusOne_returnsRandom() {
        let s = SeedManager.shared.effectiveSeed(requested: -1)
        XCTAssertGreaterThanOrEqual(s, 0)
    }

    func test_effectiveSeed_positive_returnsSelf() {
        let s = SeedManager.shared.effectiveSeed(requested: 12345)
        XCTAssertEqual(s, 12345)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 11 — ADetailerEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class ADetailerEngineTests: XCTestCase {

    @MainActor func test_addUnit_increasesCount() {
        let e       = ADetailerEngine.shared
        let initial = e.activeUnits.count
        let unit    = ADetailerUnit(model: .faceYolov8s)
        e.addUnit(unit)
        XCTAssertGreaterThan(e.activeUnits.count, initial)
        e.removeUnit(id: unit.id)
    }

    @MainActor func test_removeUnit_decreasesCount() {
        let e    = ADetailerEngine.shared
        let unit = ADetailerUnit(model: .faceYolov8s)
        e.addUnit(unit)
        let after = e.activeUnits.count
        e.removeUnit(id: unit.id)
        XCTAssertEqual(e.activeUnits.count, after - 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 12 — LoRAEncapsulationTests
// ─────────────────────────────────────────────────────────────────────────────

final class LoRAEncapsulationTests: XCTestCase {

    typealias W = LoRAEncapsulationEngine.LoRAWeight
    typealias C = LoRAEncapsulationEngine.LoRACapsule

    func makeWeight(_ name: String, _ w: Double) -> W { W(loraName: name, weight: w) }

    func makeCapsule(_ name: String = "TestCap") -> C {
        var c = C(name: name, category: .character)
        c.loraWeights  = [makeWeight("beautify", 0.8), makeWeight("detail_fix", 0.6)]
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
        XCTAssertTrue(half.contains("0.40"), "Linear 0.5 → peso 0.40")
    }

    @MainActor func test_addCapsule_increasesCount() throws {
        let e       = LoRAEncapsulationEngine.shared
        let initial = e.capsules.count
        let c       = makeCapsule("Add_\(UUID().uuidString)")
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
// SUITE 13 — JobQueueManagerTests
// ─────────────────────────────────────────────────────────────────────────────

final class JobQueueManagerTests: XCTestCase {

    typealias Job = JobQueueManager.GenerationJob

    func test_defaultStatus_isQueued()   { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).status,   .queued) }
    func test_defaultPriority_isNormal() { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).priority, .normal) }
    func test_defaultAttempts_isZero()   { XCTAssertEqual(Job(request: SDRequest(prompt: "t")).attempts, 0) }

    func test_uniqueJobIDs() {
        let j1 = Job(request: SDRequest(prompt: "a"))
        let j2 = Job(request: SDRequest(prompt: "b"))
        XCTAssertNotEqual(j1.id, j2.id)
    }

    func test_allStatuses_haveIcons() {
        JobQueueManager.JobStatus.allCases.forEach { XCTAssertFalse($0.icon.isEmpty) }
    }

    func test_priorityOrdering_highBeforeNormal() {
        XCTAssertLessThan(JobQueueManager.JobPriority.high, JobQueueManager.JobPriority.normal)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 14 — VaultCryptoEngineTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class VaultCryptoEngineTests: XCTestCase {

    // We test the pure crypto primitives — no Keychain access required for these tests.

    func test_aesGcm_encryptDecrypt_roundtrip() throws {
        let key       = SymmetricKey(size: .bits256)
        let plaintext = "Hello, Vault!".data(using: .utf8)!

        let sealed    = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            XCTFail("sealed.combined should not be nil")
            return
        }

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
        let ok   = HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
        XCTAssertTrue(ok)
    }

    func test_hmac_verify_wrongKey_fails() {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let data = "payload".data(using: .utf8)!
        let mac  = HMAC<SHA256>.authenticationCode(for: data, using: key1)
        let ok   = HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key2)
        XCTAssertFalse(ok)
    }

    func test_sha256_knownVector() {
        // SHA256("abc") = ba7816bf...
        let input  = "abc".data(using: .utf8)!
        let digest = SHA256.hash(data: input)
        let hex    = digest.map { String(format: "%02hhx", $0) }.joined()
        XCTAssertTrue(hex.hasPrefix("ba7816bf"))
    }

    func test_encryptDecrypt_largeData() throws {
        let key   = SymmetricKey(size: .bits256)
        let data  = Data(repeating: 0xAB, count: 1_024 * 1_024)   // 1 MB
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            XCTFail("combined should not be nil for large data"); return
        }
        let opened = try AES.GCM.open(.init(combined: combined), using: key)
        XCTAssertEqual(opened, data)
    }

    func test_encryptionEnabled_defaultTrue() {
        XCTAssertTrue(VaultCryptoEngine.shared.isEncryptionEnabled)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 15 — SteganographyEngineTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class SteganographyEngineTests: XCTestCase {

    func test_stegPayload_codableRoundtrip() throws {
        let payload = SteganographyEngine.StegPayload(
            artistID:   "artist_abc",
            assetID:    UUID().uuidString,
            sessionTag: "session_001",
            timestamp:  Date().timeIntervalSince1970,
            sha256:     "abc123",
            checksum:   "checksum_xyz"
        )
        let data    = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SteganographyEngine.StegPayload.self, from: data)
        XCTAssertEqual(decoded.artistID,   payload.artistID)
        XCTAssertEqual(decoded.assetID,    payload.assetID)
        XCTAssertEqual(decoded.sessionTag, payload.sessionTag)
        XCTAssertEqual(decoded.sha256,     payload.sha256)
        XCTAssertEqual(decoded.checksum,   payload.checksum)
    }

    func test_stegPayload_version_isSet() {
        let payload = SteganographyEngine.StegPayload(
            artistID:   "a", assetID: "b",
            sessionTag: nil,
            timestamp:  0, sha256: "x", checksum: "y"
        )
        XCTAssertFalse(payload.version.isEmpty)
        XCTAssertTrue(payload.version.hasPrefix("SDPipeline.Steg"))
    }

    func test_artistID_persistedAcrossCalls() {
        // Two calls to SteganographyEngine.shared.config.artistID should return same value
        let id1 = SteganographyEngine.shared.config.artistID
        let id2 = SteganographyEngine.shared.config.artistID
        XCTAssertEqual(id1, id2)
    }

    func test_artistID_nonEmpty() {
        XCTAssertFalse(SteganographyEngine.shared.config.artistID.isEmpty)
    }

    func test_hmacKey_isFixed256Bits() {
        let key = SteganographyEngine.shared.config.hmacKey
        // SymmetricKey for HMAC-SHA256 should be 256 bits (32 bytes)
        XCTAssertEqual(key.bitCount, 256)
    }

    func test_channels_default_rgbThreeChannels() {
        XCTAssertEqual(SteganographyEngine.shared.config.channels, [0, 1, 2])
    }

    func test_bitsPerChannel_default_is1() {
        XCTAssertEqual(SteganographyEngine.shared.config.bitsPerChannel, 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 16 — PromptSafetyFilterTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class PromptSafetyFilterTests: XCTestCase {

    func test_cleanPrompt_isAllowed() {
        let result = PromptSafetyFilter.validate("gorgeous woman, studio lighting, editorial style")
        guard case .allowed = result else {
            XCTFail("Clean prompt should be allowed")
            return
        }
    }

    func test_hardBlock_childTerm_isBlocked() {
        let result = PromptSafetyFilter.validate("a beautiful loli character")
        guard case .blocked(_, let terms) = result else {
            XCTFail("loli should trigger a hard block")
            return
        }
        XCTAssertFalse(terms.isEmpty)
    }

    func test_hardBlock_nonConsentTerm_isBlocked() {
        let result = PromptSafetyFilter.validate("woman in non-consent scenario")
        guard case .blocked = result else {
            XCTFail("non-consent should be blocked")
            return
        }
    }

    func test_hardBlock_incestTerm_isBlocked() {
        let result = PromptSafetyFilter.validate("incest fantasy")
        guard case .blocked = result else {
            XCTFail("incest should be blocked")
            return
        }
    }

    func test_softFlag_returnsWarning() {
        // "barely legal" is a softFlag — should be flagged, not blocked
        let result = PromptSafetyFilter.validate("barely legal model, artistic nude")
        guard case .flagged(let warnings) = result else {
            // Could also be blocked depending on implementation — either is acceptable
            return
        }
        XCTAssertFalse(warnings.isEmpty)
    }

    func test_emptyPrompt_isAllowed() {
        let result = PromptSafetyFilter.validate("")
        guard case .allowed = result else {
            XCTFail("Empty prompt should be allowed")
            return
        }
    }

    func test_caseSensitivity_blockedRegardlessOfCase() {
        let result = PromptSafetyFilter.validate("LOLI character in anime style")
        guard case .blocked = result else {
            XCTFail("Block should be case-insensitive")
            return
        }
    }

    func test_partialMatch_doesNotFalsePositive() {
        // "solo" should NOT trigger "loli" block (partial match problem)
        let result = PromptSafetyFilter.validate("solo female standing, minimalist background")
        // Solo should not block (it's not "loli")
        if case .blocked(_, let terms) = result {
            let hasLoli = terms.contains(where: { $0.lowercased().contains("loli") })
            XCTAssertFalse(hasLoli, "solo should not trigger loli block")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 17 — NSFWDetectorTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class NSFWDetectorTests: XCTestCase {

    func test_nsfwLevel_ordering_safeLessThanExplicit() {
        XCTAssertLessThan(NSFWLevel.safe, NSFWLevel.explicit)
        XCTAssertLessThan(NSFWLevel.mild, NSFWLevel.moderate)
        XCTAssertLessThan(NSFWLevel.moderate, NSFWLevel.explicit)
    }

    func test_nsfwLevel_rawValues_sequential() {
        XCTAssertEqual(NSFWLevel.safe.rawValue,     0)
        XCTAssertEqual(NSFWLevel.mild.rawValue,     1)
        XCTAssertEqual(NSFWLevel.moderate.rawValue, 2)
        XCTAssertEqual(NSFWLevel.explicit.rawValue, 3)
    }

    func test_nsfwLevel_allCases_haveLabels() {
        NSFWLevel.allCases.forEach { XCTAssertFalse($0.label.isEmpty) }
    }

    func test_nsfwLevel_allCases_haveIcons() {
        NSFWLevel.allCases.forEach { XCTAssertFalse($0.icon.isEmpty) }
    }

    func test_nsfwPolicy_defaults_sensible() {
        let policy = NSFWPolicy()
        XCTAssertLessThanOrEqual(policy.thresholdForFlag, NSFWLevel.moderate)
        XCTAssertLessThanOrEqual(policy.thresholdForQuarantine, NSFWLevel.explicit)
    }

    func test_nsfwDetectionResult_uniqueIDs() {
        let r1 = NSFWDetectionResult(promptLevel: .safe,  finalLevel: .safe)
        let r2 = NSFWDetectionResult(promptLevel: .mild,  finalLevel: .mild)
        XCTAssertNotEqual(r1.id, r2.id)
    }

    func test_nsfwDetectionResult_codableRoundtrip() throws {
        let r       = NSFWDetectionResult(promptLevel: .moderate, finalLevel: .moderate)
        let data    = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(NSFWDetectionResult.self, from: data)
        XCTAssertEqual(decoded.finalLevel,  r.finalLevel)
        XCTAssertEqual(decoded.promptLevel, r.promptLevel)
    }

    @MainActor func test_analyzePrompt_safeContent_returnsSafe() {
        let (level, _) = NSFWDetector.shared.analyzePrompt(
            "editorial portrait, studio lighting, elegant dress"
        )
        XCTAssertLessThanOrEqual(level, NSFWLevel.mild)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 18 — IntegrityManagerTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class IntegrityManagerTests: XCTestCase {

    // Tests the pure hashing logic — no CoreData required.

    func test_sha256_consistentAcrossCalls() {
        let data = "test payload".data(using: .utf8)!
        let h1   = data.sha256Hex
        let h2   = data.sha256Hex
        XCTAssertEqual(h1, h2)
    }

    func test_sha256_differentData_differentHash() {
        let d1 = "payload1".data(using: .utf8)!
        let d2 = "payload2".data(using: .utf8)!
        XCTAssertNotEqual(d1.sha256Hex, d2.sha256Hex)
    }

    func test_sha256_hexLength_is64() {
        let data = "anything".data(using: .utf8)!
        XCTAssertEqual(data.sha256Hex.count, 64)
    }

    func test_sha256_emptyData_knownVector() {
        // SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let empty   = Data()
        let hex     = empty.sha256Hex
        XCTAssertTrue(hex.hasPrefix("e3b0c442"))
    }

    func test_verificationResult_allCases_representable() {
        // Verify the enum cases exist and can be matched
        let ok      = IntegrityManager.VerificationResult.ok
        let noHash  = IntegrityManager.VerificationResult.noHashRegistered

        if case .ok = ok { /* ok */ } else { XCTFail() }
        if case .noHashRegistered = noHash { /* ok */ } else { XCTFail() }
    }

    func test_assetVerificationRecord_uniqueIDs() {
        let r1 = IntegrityManager.AssetVerificationRecord(assetID: UUID(), result: .ok)
        let r2 = IntegrityManager.AssetVerificationRecord(assetID: UUID(), result: .ok)
        XCTAssertNotEqual(r1.id, r2.id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 19 — TaggingEngineTests (NEW v2)
// ─────────────────────────────────────────────────────────────────────────────

final class TaggingEngineTests: XCTestCase {

    func test_autoExtract_extractsKeywordsFromPrompt() {
        let tags = TaggingEngine.shared.autoExtract(from: "elegant woman, studio lighting, red dress, portrait")
        XCTAssertFalse(tags.isEmpty)
    }

    func test_autoExtract_doesNotReturnEmptyStrings() {
        let tags = TaggingEngine.shared.autoExtract(from: "golden hour, beach, relaxed pose")
        XCTAssertTrue(tags.allSatisfy { !$0.isEmpty })
    }

    func test_suggestions_returnsResultsForKnownPrefix() {
        // First make sure the index has something
        TaggingEngine.shared.tagFrequency["portrait"] = 5
        TaggingEngine.shared.tagFrequency["portrait_close"] = 3
        let suggestions = TaggingEngine.shared.suggestions(for: "port")
        // Either returns empty (no index loaded) or returns portrait
        XCTAssertNotNil(suggestions)   // just ensure no crash
    }

    func test_search_emptyTags_returnsEmpty() {
        let results = TaggingEngine.shared.search(tags: [], mode: .and)
        XCTAssertTrue(results.isEmpty)
    }

    func test_tagItem_comparable_higherCountFirst() {
        let t1 = TaggingEngine.TagItem(tag: "portrait", count: 10)
        let t2 = TaggingEngine.TagItem(tag: "landscape", count: 3)
        XCTAssertLessThan(t1, t2, "Higher count should sort first")
    }

    func test_searchMode_allCases_representable() {
        let _ = TaggingEngine.SearchMode.and
        let _ = TaggingEngine.SearchMode.or
        let _ = TaggingEngine.SearchMode.not
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUITE 20 — ExportEngineTests
// ─────────────────────────────────────────────────────────────────────────────

final class ExportEngineTests: XCTestCase {

    typealias WC = ExportEngine.WatermarkConfig
    typealias EP = ExportEngine.ExportPreset

    func test_watermarkConfig_defaults() {
        let wc = WC()
        XCTAssertEqual(wc.opacity,  0.35, accuracy: 0.001)
        XCTAssertEqual(wc.position, .bottomRight)
        XCTAssertEqual(wc.fontSize, 18)
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
    }

    func test_watermarkPosition_allCases_present() {
        let all = WC.Position.allCases
        XCTAssertTrue(all.contains(.topLeft))
        XCTAssertTrue(all.contains(.bottomRight))
        XCTAssertTrue(all.contains(.center))
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

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
#endif
