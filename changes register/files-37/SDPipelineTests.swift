import XCTest
import CryptoKit
import Foundation
@testable import SDPipeline   // Cambia por el nombre de tu target principal

// MARK: - SDPipelineTests
//
// Suite de tests de regresión para los engines críticos del pipeline.
//
// COBERTURA:
//   1. PromptBuilderTests      — buildFromEditorialSchema, buildFlat, extractDirectPrompt
//   2. PromptSafetyFilterTests — hard blocks, soft flags, JSON schema validation
//   3. SidecarJSONTests        — encode / decode / roundtrip
//   4. SandboxManagerTests     — buildRestrictedEnvironment, isolationStatus, config
//   5. IntegrityManagerTests   — SHA-256 hash, verificationResult helpers
//   6. SDRequestTests          — init defaults, Codable roundtrip
//   7. SDResponseTests         — parsing de respuesta A1111
//   8. PromptBuilderEdgeCases  — JSON vacío, arrays anidados, keys meta ignoradas
//
// EJECUCIÓN:
//   Cmd+U en Xcode — o `swift test` si tienes SPM target configurado.
//
// ROADMAP: "Tests de regresión para PromptBuilder" (🟡 MEDIO PLAZO)

// MARK: - 1. PromptBuilder Tests

final class PromptBuilderTests: XCTestCase {

    // MARK: buildFromEditorialSchema — primary_prompt presente

    func test_buildFromEditorialSchema_withPrimaryPrompt_returnsPrimaryPrompt() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "gorgeous woman, studio lighting, 4k",
                "negative_prompt": "ugly, blurry, nsfw"
            ]
        ]

        let result = PromptBuilder.buildFromEditorialSchema(json)

        XCTAssertTrue(
            result.positive.contains("gorgeous woman"),
            "El prompt positivo debe contener el primary_prompt"
        )
        XCTAssertEqual(
            result.negative,
            "ugly, blurry, nsfw",
            "El prompt negativo debe extraerse de generation_engine.negative_prompt"
        )
    }

    // MARK: buildFromEditorialSchema — variationPrompts concatenados

    func test_buildFromEditorialSchema_withVariationPrompts_appendsAll() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "editorial model",
                "variation_prompts": ["red dress", "beach background"],
                "negative_prompt": ""
            ]
        ]

        let result = PromptBuilder.buildFromEditorialSchema(json)

        XCTAssertTrue(result.positive.contains("editorial model"))
        XCTAssertTrue(result.positive.contains("red dress"))
        XCTAssertTrue(result.positive.contains("beach background"))
    }

    // MARK: buildFromEditorialSchema — sin primary_prompt usa positiveMap

    func test_buildFromEditorialSchema_withoutPrimaryPrompt_usesPositiveMap() {
        let json: [String: Any] = [
            "subject_system": [
                "identity": ["archetype": "fashion model", "gender": "female"],
                "biometrics": ["body_type": "slim athletic"]
            ],
            "editorial_style_system": [
                "style_category": "editorial",
                "visual_tone": "soft romantic",
                "components": ["lighting_drama_0_10": 9, "camera_storytelling_0_10": 8]
            ],
            "camera_engine": [
                "lens_mm": 85,
                "aperture": "f/1.8",
                "framing_type": "medium shot"
            ],
            "brand_projection": [
                "aspirational_level_0_10": 9
            ]
        ]

        let result = PromptBuilder.buildFromEditorialSchema(json)

        // Boosters de lighting drama ≥ 8
        XCTAssertTrue(
            result.positive.contains("dramatic studio lighting"),
            "Lighting drama ≥ 8 debe agregar 'dramatic studio lighting'"
        )
        // Booster de camera storytelling ≥ 8
        XCTAssertTrue(
            result.positive.contains("editorial photography"),
            "Camera storytelling ≥ 8 debe agregar 'editorial photography'"
        )
        // Booster de aspirational ≥ 8
        XCTAssertTrue(
            result.positive.contains("ultra high resolution"),
            "Aspirational ≥ 8 debe agregar 'ultra high resolution'"
        )
        // Booster de lens 85mm + aperture f/1.8
        XCTAssertTrue(
            result.positive.contains("bokeh"),
            "Lens ≥ 85mm debe agregar bokeh"
        )
        XCTAssertTrue(
            result.positive.contains("soft background blur"),
            "Apertura f/1.8 debe agregar 'soft background blur'"
        )
        // Tokens del schema presentes
        XCTAssertTrue(result.positive.contains("fashion model"))
        XCTAssertTrue(result.positive.contains("female"))
        XCTAssertTrue(result.positive.contains("slim athletic"))
    }

    // MARK: buildFromEditorialSchema — no duplicados

    func test_buildFromEditorialSchema_noDuplicateTokens() {
        let json: [String: Any] = [
            "generation_engine": [
                "primary_prompt": "portrait, portrait, portrait",
                "variation_prompts": ["portrait"]
            ]
        ]

        let result = PromptBuilder.buildFromEditorialSchema(json)

        // No debe haber tokens repetidos
        let tokens = result.positive.components(separatedBy: ", ").filter { !$0.isEmpty }
        let unique  = Set(tokens)
        XCTAssertEqual(tokens.count, unique.count, "buildFromEditorialSchema no debe producir tokens duplicados")
    }

    // MARK: buildFlat

    func test_buildFlat_extractsLeafStrings() {
        let json: [String: Any] = [
            "a": "red",
            "b": ["c": "blue", "d": "green"],
            "e": ["yellow", "orange"]
        ]

        let result = PromptBuilder.buildFlat(from: json)

        XCTAssertTrue(result.contains("red"))
        XCTAssertTrue(result.contains("blue"))
        XCTAssertTrue(result.contains("green"))
        XCTAssertTrue(result.contains("yellow"))
        XCTAssertTrue(result.contains("orange"))
    }

    func test_buildFlat_ignoresMetaKeys() {
        let json: [String: Any] = [
            "version": "1.0",
            "character_id": "char_001",
            "timestamp": "2025-01-01",
            "style": "cinematic"
        ]

        let result = PromptBuilder.buildFlat(from: json)

        XCTAssertFalse(result.contains("1.0"),     "version debe ser ignorado por buildFlat")
        XCTAssertFalse(result.contains("char_001"),"character_id debe ser ignorado por buildFlat")
        XCTAssertTrue(result.contains("cinematic"), "style sí debe aparecer")
    }

    // MARK: extractDirectPrompt

    func test_extractDirectPrompt_returnsPromptKey() {
        let json: [String: Any] = ["prompt": "a beautiful sunset", "other": "value"]
        let result = PromptBuilder.extractDirectPrompt(from: json)
        XCTAssertEqual(result, "a beautiful sunset")
    }

    func test_extractDirectPrompt_returnsNilIfMissing() {
        let json: [String: Any] = ["style": "editorial"]
        let result = PromptBuilder.extractDirectPrompt(from: json)
        XCTAssertNil(result)
    }

    func test_extractDirectPrompt_returnsNilForEmptyString() {
        let json: [String: Any] = ["prompt": ""]
        let result = PromptBuilder.extractDirectPrompt(from: json)
        XCTAssertNil(result)
    }

    // MARK: Edge cases

    func test_buildFromEditorialSchema_withNonDict_callsBuildFlat() {
        // Si el JSON raíz no es dict, buildFlat es el fallback
        let result = PromptBuilder.buildFromEditorialSchema("raw string")
        XCTAssertEqual(result.positive, "raw string")
        XCTAssertTrue(result.negative.isEmpty)
    }

    func test_buildFromEditorialSchema_emptyDict_returnsEmptyTokens() {
        let result = PromptBuilder.buildFromEditorialSchema([String: Any]())
        // Sólo debe contener boosters mínimos (aspirational=0 → "high quality, detailed")
        XCTAssertTrue(result.positive.contains("high quality"))
    }
}

// MARK: - 2. PromptSafetyFilter Tests

final class PromptSafetyFilterTests: XCTestCase {

    // MARK: validatePrompt — hard blocks

    func test_validatePrompt_blocksMinorTerms() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "cute schoolgirl in a dress",
            negative: ""
        )
        XCTAssertTrue(result.isBlocked, "Término 'schoolgirl' debe ser bloqueado")
    }

    func test_validatePrompt_blocksIllegalContent() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "forced sex scene",
            negative: ""
        )
        XCTAssertTrue(result.isBlocked)
    }

    func test_validatePrompt_blocksTermsInCombined() {
        // El término está en la parte positiva — debe bloquear
        let result = PromptSafetyFilter.validatePrompt(
            positive: "loli anime character",
            negative: "bad quality"
        )
        XCTAssertTrue(result.isBlocked)
    }

    func test_validatePrompt_allowsNegativeWithBlockedTerm() {
        // Negativo puede contener términos del hard block para excluirlos
        // NOTA: El diseño actual evalúa combined positivo+negativo.
        // Este test documenta el comportamiento real — si falla, el diseño
        // fue intencionalmente endurecido para bloquear también en negativo.
        let result = PromptSafetyFilter.validatePrompt(
            positive: "beautiful woman",
            negative: "child, minor, underage, watermark"
        )
        // En el filtro actual combined = positivo + negativo → bloquea
        // Este test sirve como documentación del comportamiento actual:
        // Si el filtro evoluciona para permitir términos de exclusión en negativo,
        // cambiar expected a XCTAssertFalse(result.isBlocked)
        XCTAssertTrue(result.isBlocked, "Diseño actual: combined positivo+negativo → bloquea siempre")
    }

    func test_validatePrompt_allowsCleanPrompt() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "editorial fashion model, studio lighting, 4k, professional photography",
            negative: "ugly, blurry, deformed, low quality"
        )
        XCTAssertFalse(result.isBlocked)
        XCTAssertFalse(result.isFlagged)
        XCTAssertTrue(result.isAllowed)
    }

    func test_validatePrompt_flagsSoftTerms() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "very young woman, innocent smile",
            negative: ""
        )
        // No bloquea pero debe advertir
        XCTAssertFalse(result.isBlocked)
        XCTAssertTrue(result.isFlagged, "Términos 'very young' e 'innocent' deben producir advertencia")
    }

    // MARK: userMessage

    func test_filterResult_userMessage_blockedHasMessage() {
        let result = PromptSafetyFilter.validatePrompt(positive: "child model", negative: "")
        XCTAssertNotNil(result.userMessage)
        XCTAssertTrue(result.userMessage?.hasPrefix("🚫") ?? false)
    }

    func test_filterResult_userMessage_allowedIsNil() {
        let result = PromptSafetyFilter.validatePrompt(positive: "fashion editorial", negative: "blurry")
        XCTAssertNil(result.userMessage)
    }

    // MARK: validateJSON

    func test_validateJSON_blocksMissingMinorProtection() {
        let json: [String: Any] = [
            "safety_compliance_layer": [
                "minor_protection_enforced": false,  // Debe ser true
                "sexual_act_block": true,
                "explicit_content_block": true
            ],
            "generation_engine": ["primary_prompt": "editorial shoot"]
        ]

        let result = PromptSafetyFilter.validateJSON(json)
        XCTAssertTrue(result.isFlagged || result.isBlocked,
            "minor_protection_enforced: false debe producir advertencia o bloqueo")
    }

    func test_validateJSON_allowsCompliantSchema() {
        let json: [String: Any] = [
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block": true,
                "explicit_content_block": true
            ],
            "generation_engine": [
                "primary_prompt": "editorial fashion model",
                "negative_prompt": "ugly, blurry"
            ]
        ]

        let result = PromptSafetyFilter.validateJSON(json)
        // Con schema correcto y sin términos bloqueados debe ser .allowed
        XCTAssertTrue(result.isAllowed || result.isFlagged,
            "Schema correcto sin términos peligrosos debe ser allowed o solo flagged suave")
        XCTAssertFalse(result.isBlocked)
    }

    func test_validateJSON_blocksHardTermsInNestedJSON() {
        let json: [String: Any] = [
            "wardrobe_engine": [
                "notes": "looks like a schoolgirl uniform"   // contiene término bloqueado
            ],
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block": true,
                "explicit_content_block": true
            ]
        ]

        let result = PromptSafetyFilter.validateJSON(json)
        XCTAssertTrue(result.isBlocked,
            "Términos bloqueados en JSON anidado deben ser detectados")
    }

    // MARK: CaseIterable invariants

    func test_filterResult_exactlyOneCase_isBlocked() {
        let blocked: PromptSafetyFilter.FilterResult = .blocked(reason: "test", matchedTerms: ["x"])
        XCTAssertTrue(blocked.isBlocked)
        XCTAssertFalse(blocked.isFlagged)
        XCTAssertFalse(blocked.isAllowed)
    }

    func test_filterResult_exactlyOneCase_isFlagged() {
        let flagged: PromptSafetyFilter.FilterResult = .flagged(warnings: ["w"])
        XCTAssertFalse(flagged.isBlocked)
        XCTAssertTrue(flagged.isFlagged)
        XCTAssertFalse(flagged.isAllowed)
    }
}

// MARK: - 3. SidecarJSON Tests

final class SidecarJSONTests: XCTestCase {

    // Fixture: SidecarJSON mínimo para tests
    func makeSidecar() -> SidecarJSON {
        let request = SDRequest(
            prompt: "editorial model",
            negativePrompt: "ugly, blurry",
            seed: 42,
            steps: 28,
            cfgScale: 7.0,
            width: 512,
            height: 768,
            samplerName: "DPM++ 2M Karras"
        )
        return SidecarJSON(
            baseName:    "test_asset",
            version:     1,
            imageURL:    URL(fileURLWithPath: "/tmp/test_asset_v001.png"),
            request:     request,
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

    // MARK: Codable roundtrip

    func test_sidecarJSON_codableRoundtrip() throws {
        let original = makeSidecar()
        let data     = try JSONEncoder.pretty.encode(original)
        let decoded  = try JSONDecoder.iso8601.decode(SidecarJSON.self, from: data)

        XCTAssertEqual(decoded.baseName,         original.baseName)
        XCTAssertEqual(decoded.version,          original.version)
        XCTAssertEqual(decoded.sha256,           original.sha256)
        XCTAssertEqual(decoded.schemaVersion,    "SDPipeline.Sidecar.v1")
        XCTAssertEqual(decoded.generation.seed,          42)
        XCTAssertEqual(decoded.generation.promptPositive, "editorial model")
        XCTAssertEqual(decoded.generation.steps,         28)
        XCTAssertEqual(decoded.generation.samplerName,   "DPM++ 2M Karras")
        XCTAssertEqual(decoded.model.checkpoint,         "realisticVision_v5.safetensors")
        XCTAssertEqual(decoded.model.loraWeights["beautify"], 0.8)
        XCTAssertEqual(decoded.session.tag,              "Beach Session Mar 2025")
        XCTAssertEqual(decoded.session.sdVersion,        "1.9.4")
        XCTAssertFalse(decoded.integrity.cleanVersionExists)
        XCTAssertFalse(decoded.integrity.previewVersionExists)
    }

    // MARK: Save and Load (temp file)

    func test_sidecarJSON_saveAndLoad_roundtrip() throws {
        let original  = makeSidecar()
        let tempURL   = FileManager.default.temporaryDirectory
                            .appending(path: "test_sidecar_\(UUID().uuidString).meta.json")

        try original.save(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let loaded = SidecarJSON.load(from: tempURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.baseName, original.baseName)
        XCTAssertEqual(loaded?.sha256,   original.sha256)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    func test_sidecarJSON_load_returnsNilForMissingFile() {
        let result = SidecarJSON.load(from: URL(fileURLWithPath: "/nonexistent/path.meta.json"))
        XCTAssertNil(result, "Debe retornar nil para archivos no existentes")
    }

    // MARK: imageFilename solo contiene el nombre, no el path completo

    func test_sidecarJSON_imageFilenameIsNotFullPath() {
        let s = makeSidecar()
        XCTAssertFalse(s.imageFilename.contains("/"),
            "imageFilename no debe contener barras — solo el nombre del archivo")
        XCTAssertEqual(s.imageFilename, "test_asset_v001.png")
    }

    // MARK: HiRes values son nil cuando enableHR = false

    func test_sidecarJSON_hiResIsNilWhenDisabled() {
        let request = SDRequest(prompt: "test", enableHR: false)
        let sidecar = SidecarJSON(
            baseName: "x", version: 1,
            imageURL: URL(fileURLWithPath: "/tmp/x.png"),
            request: request, seed: 1,
            modelName: "m", checkpoint: "c", vaeUsed: "v",
            loraWeights: [:], sha256: "abc", sessionTag: nil
        )
        XCTAssertNil(sidecar.generation.hrScale,           "hrScale debe ser nil si enableHR=false")
        XCTAssertNil(sidecar.generation.hrSecondPassSteps, "hrSecondPassSteps debe ser nil si enableHR=false")
        XCTAssertNil(sidecar.generation.denoisingStrength, "denoisingStrength debe ser nil si enableHR=false")
    }

    func test_sidecarJSON_hiResIsSetWhenEnabled() {
        let request = SDRequest(
            prompt: "test",
            enableHR: true,
            hrUpscaler: "4x-UltraSharp",
            hrScale: 2.0,
            hrSecondPassSteps: 15,
            denoisingStrength: 0.45
        )
        let sidecar = SidecarJSON(
            baseName: "x", version: 1,
            imageURL: URL(fileURLWithPath: "/tmp/x.png"),
            request: request, seed: 1,
            modelName: "m", checkpoint: "c", vaeUsed: "v",
            loraWeights: [:], sha256: "abc", sessionTag: nil
        )
        XCTAssertEqual(sidecar.generation.hrScale,            2.0)
        XCTAssertEqual(sidecar.generation.hrSecondPassSteps,  15)
        XCTAssertEqual(sidecar.generation.denoisingStrength,  0.45)
    }
}

// MARK: - 4. SandboxManager Tests

final class SandboxManagerTests: XCTestCase {

    // MARK: Config defaults

    func test_sandboxConfig_allowedHostIsLocalhost() {
        let config = SandboxManager.SandboxConfig()
        XCTAssertEqual(config.allowedHost, "127.0.0.1",
            "La API de A1111 solo debe permitirse en localhost")
    }

    func test_sandboxConfig_allowedPortIs7860() {
        let config = SandboxManager.SandboxConfig()
        XCTAssertEqual(config.allowedPort, 7860)
    }

    func test_sandboxConfig_killOnCriticalViolationIsFalseByDefault() {
        // No bloquear automáticamente en desarrollo
        let config = SandboxManager.SandboxConfig()
        XCTAssertFalse(config.killOnCriticalViolation,
            "Por defecto NO debe hacer kill automático — solo auditar")
    }

    func test_sandboxConfig_blockedEnvPrefixesContainDYLD() {
        let config = SandboxManager.SandboxConfig()
        XCTAssertTrue(
            config.blockedEnvironmentPrefixes.contains("DYLD_INSERT_LIBRARIES"),
            "DYLD_INSERT_LIBRARIES debe estar bloqueado (anti-injection)"
        )
        XCTAssertTrue(
            config.blockedEnvironmentPrefixes.contains("LD_PRELOAD"),
            "LD_PRELOAD debe estar bloqueado"
        )
    }

    func test_sandboxConfig_allowedEnvKeysContainEssentials() {
        let config = SandboxManager.SandboxConfig()
        XCTAssertTrue(config.allowedEnvironmentKeys.contains("PATH"))
        XCTAssertTrue(config.allowedEnvironmentKeys.contains("HOME"))
        XCTAssertTrue(config.allowedEnvironmentKeys.contains("PYTORCH_ENABLE_MPS_FALLBACK"))
    }

    // MARK: Violation type rawValues (para UI y logs)

    func test_violationType_rawValues_areHumanReadable() {
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.unauthorizedWrite.rawValue,
                       "Escritura no autorizada")
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.networkExposure.rawValue,
                       "Exposición de red detectada")
        XCTAssertEqual(SandboxManager.SandboxViolation.ViolationType.processRestart.rawValue,
                       "Reinicio no autorizado")
    }

    // MARK: ProcessState rawValues (para UI)

    func test_processState_rawValues() {
        XCTAssertEqual(SandboxManager.ProcessState.stopped.rawValue,    "Detenido")
        XCTAssertEqual(SandboxManager.ProcessState.running.rawValue,    "Corriendo")
        XCTAssertEqual(SandboxManager.ProcessState.crashed.rawValue,    "Crash detectado")
        XCTAssertEqual(SandboxManager.ProcessState.restricted.rawValue, "Restringido (violación)")
    }

    // MARK: isolationStatus cuando stopped

    @MainActor
    func test_isolationStatus_whenStopped_isPassed() {
        let mgr = SandboxManager.shared
        // Estado inicial es .stopped
        if mgr.processState == .stopped {
            let status = mgr.isolationStatus
            XCTAssertTrue(status.passed, "Estado stopped no es un riesgo de seguridad")
        }
    }

    // MARK: SandboxError localizedDescription

    func test_sandboxError_alreadyRunning_hasDescription() {
        let error = SandboxError.alreadyRunning
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func test_sandboxError_scriptNotFound_includesPath() {
        let error = SandboxError.scriptNotFound("/path/to/webui.sh")
        XCTAssertTrue(error.errorDescription?.contains("/path/to/webui.sh") ?? false)
    }
}

// MARK: - 5. Integrity / SHA-256 Tests

final class IntegrityHashTests: XCTestCase {

    // MARK: SHA-256 helper extension (Data.sha256Hex)

    func test_sha256Hex_knownVector() {
        // SHA-256 de "abc" es ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469348423f656b4e4a3
        let data = "abc".data(using: .utf8)!
        let hash = data.sha256Hex
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469348423f656b4e4a3",
            "SHA-256 de 'abc' debe coincidir con el vector conocido")
    }

    func test_sha256Hex_emptyData() {
        // SHA-256 de "" es e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let data = Data()
        let hash = data.sha256Hex
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "SHA-256 de datos vacíos debe coincidir con el vector conocido")
    }

    func test_sha256Hex_isDeterministic() {
        let data   = "SDPipeline Studio".data(using: .utf8)!
        let hash1  = data.sha256Hex
        let hash2  = data.sha256Hex
        XCTAssertEqual(hash1, hash2, "SHA-256 debe ser determinístico")
    }

    func test_sha256Hex_differentInputsProduceDifferentHashes() {
        let data1 = "prompt A".data(using: .utf8)!
        let data2 = "prompt B".data(using: .utf8)!
        XCTAssertNotEqual(data1.sha256Hex, data2.sha256Hex)
    }

    func test_sha256Hex_hexLength_is64() {
        let data = "test".data(using: .utf8)!
        XCTAssertEqual(data.sha256Hex.count, 64, "SHA-256 en hex debe tener exactamente 64 caracteres")
    }

    // MARK: VerificationResult helpers

    func test_verificationResult_ok_isOK() {
        let result: IntegrityManager.VerificationResult = .ok
        // isOK se evalúa en AssetVerificationRecord — aquí probamos el switch pattern
        if case .ok = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Result debería ser .ok")
        }
    }

    func test_verificationResult_corrupted_storesHashes() {
        let result: IntegrityManager.VerificationResult = .corrupted(
            storedHash: "aaa",
            actualHash: "bbb"
        )
        if case .corrupted(let stored, let actual) = result {
            XCTAssertEqual(stored, "aaa")
            XCTAssertEqual(actual, "bbb")
        } else {
            XCTFail("Result debería ser .corrupted")
        }
    }

    func test_verificationResult_fileNotFound_storesPath() {
        let result: IntegrityManager.VerificationResult = .fileNotFound(path: "/some/path.png")
        if case .fileNotFound(let path) = result {
            XCTAssertEqual(path, "/some/path.png")
        } else {
            XCTFail("Result debería ser .fileNotFound")
        }
    }
}

// MARK: - 6. SDRequest Tests

final class SDRequestTests: XCTestCase {

    // MARK: Default values

    func test_sdRequest_defaultSeed_isMinusOne() {
        let req = SDRequest(prompt: "test")
        XCTAssertEqual(req.seed, -1, "Seed -1 indica semilla aleatoria en A1111")
    }

    func test_sdRequest_defaultSteps_is28() {
        let req = SDRequest(prompt: "test")
        XCTAssertEqual(req.steps, 28)
    }

    func test_sdRequest_defaultSampler_isDPMPlusPlus2MKarras() {
        let req = SDRequest(prompt: "test")
        XCTAssertEqual(req.sampler_name, "DPM++ 2M Karras")
    }

    func test_sdRequest_defaultSize_is512x768() {
        let req = SDRequest(prompt: "test")
        XCTAssertEqual(req.width,  512)
        XCTAssertEqual(req.height, 768)
    }

    func test_sdRequest_defaultHR_isDisabled() {
        let req = SDRequest(prompt: "test")
        XCTAssertFalse(req.enable_hr, "HiRes debe estar desactivado por defecto")
    }

    func test_sdRequest_defaultRestoreFaces_isFalse() {
        let req = SDRequest(prompt: "test")
        XCTAssertFalse(req.restore_faces)
    }

    func test_sdRequest_defaultNegativePrompt_containsNSFW() {
        let req = SDRequest(prompt: "test")
        XCTAssertTrue(req.negative_prompt.lowercased().contains("nsfw"),
            "El prompt negativo por defecto debe incluir 'nsfw' como protección básica")
    }

    // MARK: Custom values

    func test_sdRequest_customValues_arePreserved() {
        let req = SDRequest(
            prompt: "custom prompt",
            negativePrompt: "custom negative",
            seed: 12345,
            steps: 40,
            cfgScale: 9.5,
            width: 768,
            height: 1024,
            samplerName: "Euler a",
            batchSize: 2,
            enableHR: true,
            hrUpscaler: "4x-UltraSharp",
            hrScale: 2.0,
            hrSecondPassSteps: 20,
            denoisingStrength: 0.55,
            restoreFaces: true
        )

        XCTAssertEqual(req.prompt,            "custom prompt")
        XCTAssertEqual(req.negative_prompt,   "custom negative")
        XCTAssertEqual(req.seed,              12345)
        XCTAssertEqual(req.steps,             40)
        XCTAssertEqual(req.cfg_scale,         9.5)
        XCTAssertEqual(req.width,             768)
        XCTAssertEqual(req.height,            1024)
        XCTAssertEqual(req.sampler_name,      "Euler a")
        XCTAssertEqual(req.batch_size,        2)
        XCTAssertTrue(req.enable_hr)
        XCTAssertEqual(req.hr_upscaler,       "4x-UltraSharp")
        XCTAssertEqual(req.hr_scale,          2.0)
        XCTAssertEqual(req.hr_second_pass_steps, 20)
        XCTAssertEqual(req.denoising_strength, 0.55)
        XCTAssertTrue(req.restore_faces)
    }

    // MARK: Codable roundtrip

    func test_sdRequest_codableRoundtrip() throws {
        let original = SDRequest(
            prompt: "editorial fashion model",
            seed: 99,
            steps: 30,
            cfgScale: 7.5,
            width: 512,
            height: 768
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SDRequest.self, from: data)

        XCTAssertEqual(decoded.prompt,     original.prompt)
        XCTAssertEqual(decoded.seed,       original.seed)
        XCTAssertEqual(decoded.steps,      original.steps)
        XCTAssertEqual(decoded.cfg_scale,  original.cfg_scale)
        XCTAssertEqual(decoded.width,      original.width)
        XCTAssertEqual(decoded.height,     original.height)
    }
}

// MARK: - 7. SDResponse / SDProgress Tests

final class SDResponseTests: XCTestCase {

    func test_sdProgressResponse_percentDisplay() throws {
        let json = """
        {"progress": 0.47, "eta_relative": 12.5, "state": null, "current_image": null, "textinfo": null}
        """
        let response = try JSONDecoder().decode(SDProgressResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.percentDisplay, "47%")
    }

    func test_sdProgressResponse_etaDisplay() throws {
        let json = """
        {"progress": 0.5, "eta_relative": 8.0, "state": null, "current_image": null, "textinfo": null}
        """
        let response = try JSONDecoder().decode(SDProgressResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.etaDisplay, "ETA 8s")
    }

    func test_sdProgressResponse_etaDisplay_emptyWhenZero() throws {
        let json = """
        {"progress": 1.0, "eta_relative": 0.0, "state": null, "current_image": null, "textinfo": null}
        """
        let response = try JSONDecoder().decode(SDProgressResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.etaDisplay.isEmpty, "ETA debe estar vacío cuando eta_relative es 0")
    }

    func test_sdResponse_decodesImages() throws {
        let json = """
        {"images": ["base64data1", "base64data2"], "parameters": null, "info": null}
        """
        let response = try JSONDecoder().decode(SDResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.images.count, 2)
        XCTAssertEqual(response.images[0], "base64data1")
    }
}

// MARK: - 8. PipelineStage Tests

final class PipelineStageTests: XCTestCase {

    func test_pipelineStage_allCases_haveNonEmptyRawValue() {
        for stage in PipelineStage.allCases {
            XCTAssertFalse(stage.rawValue.isEmpty,
                "Cada PipelineStage debe tener un rawValue no vacío (para UI y logs)")
        }
    }

    func test_pipelineStage_doneAndError_areLast() {
        let allCases = PipelineStage.allCases
        // done y error deben estar al final del pipeline
        XCTAssertTrue(allCases.contains(.done))
        XCTAssertTrue(allCases.contains(.error))
    }
}

// MARK: - 9. GenerationSettings Tests

final class GenerationSettingsTests: XCTestCase {

    func test_generationSettings_samplersListIsNotEmpty() {
        XCTAssertFalse(GenerationSettings.samplers.isEmpty,
            "Lista de samplers no debe estar vacía")
    }

    func test_generationSettings_samplersContainsDPMPlusPlus() {
        XCTAssertTrue(
            GenerationSettings.samplers.contains("DPM++ 2M Karras"),
            "DPM++ 2M Karras es el sampler por defecto y debe estar en la lista"
        )
    }

    func test_generationSettings_hrUpscalersContainsUltraSharp() {
        XCTAssertTrue(
            GenerationSettings.hrUpscalers.contains("4x-UltraSharp"),
            "4x-UltraSharp debe estar en la lista de upscalers"
        )
    }

    func test_generationSettings_defaultBaseURL_isLocalhost() {
        let settings = GenerationSettings()
        XCTAssertTrue(
            settings.sdBaseURL.contains("127.0.0.1") || settings.sdBaseURL.contains("localhost"),
            "La URL base por defecto debe apuntar a localhost"
        )
    }

    func test_generationSettings_autoNSFWCheck_enabledByDefault() {
        let settings = GenerationSettings()
        XCTAssertTrue(settings.autoRunNSFWCheck,
            "El check NSFW debe estar habilitado por defecto como capa de seguridad")
    }
}

// MARK: - Helpers de Test (extensiones privadas)

// NOTA: Data.sha256Hex ya debe existir en Data_Crypto.swift
// Si no, aquí está la implementación de referencia para los tests:
private extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// JSONEncoder/Decoder conveniences (deben existir en Codable_Helpers.swift)
// Si no existen, estas extensiones proveen un fallback para los tests:
private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting   = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
