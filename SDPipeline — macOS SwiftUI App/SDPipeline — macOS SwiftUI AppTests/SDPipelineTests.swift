import XCTest
import CryptoKit
@testable import SDPipeline

// MARK: - SDPipelineTests
//
// Suite de tests unitarios para SDPipeline — macOS SwiftUI App.
//
// Organización:
//   1. Data+Crypto     — SHA-256 (vectores NIST), AES-GCM round-trip, HKDF
//   2. PromptSafetyFilter — validación de prompts y JSON del Model Builder
//   3. Codable+Helpers — JSONEncoder.pretty / JSONDecoder.iso8601
//   4. SeedManager.FavoriteSeed — Codable round-trip, igualdad, rating clamp
//   5. SDAPIRateLimiter.RequestPriority — orden de prioridades
//   6. WildcardEngine  — resolución de wildcards built-in y sin grupo
//
// ⚠️  CORRECCIONES aplicadas respecto a la versión anterior:
//   • test_sha256_knownVector_abc (línea 363 original):
//       – BUG 1: el vector esperado tenía 63 chars (faltaba '9' al final) → corregido.
//       – BUG 2: `.sha256` resolvía a una implementación hand-rolled rota → ahora
//         es un alias de `.sha256Hex` (CryptoKit) definido en Data+Crypto.swift.

final class SDPipelineTests: XCTestCase {

    // =========================================================================
    // MARK: - 1. Data+Crypto — SHA-256
    // =========================================================================

    // MARK: Vectores NIST

    /// Vector NIST SHA-256 para el mensaje "abc".
    func test_sha256_knownVector_abc() {
        let input = "abc".data(using: .utf8)!
        // Vector NIST correcto y real para "abc"
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        XCTAssertEqual(input.sha256,    expected, "sha256 (alias) debe coincidir con vector NIST")
        XCTAssertEqual(input.sha256Hex, expected, "sha256Hex (canónico) debe coincidir con vector NIST")
        XCTAssertEqual(input.sha256.count, 64,    "SHA-256 siempre produce exactamente 64 dígitos hex")
    }

    /// Vector NIST SHA-256 para el mensaje vacío.
    func test_sha256_knownVector_emptyData() {
        let input    = Data()
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(input.sha256, expected)
        XCTAssertEqual(input.sha256.count, 64)
    }

    /// Vector NIST SHA-256 — mensaje de 448 bits.
    func test_sha256_knownVector_448bit() {
        let input    = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".data(using: .utf8)!
        let expected = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        XCTAssertEqual(input.sha256, expected)
    }

    /// Vector NIST SHA-256 — mensaje "The quick brown fox…".
    func test_sha256_knownVector_foxDot() {
        let input    = "The quick brown fox jumps over the lazy dog.".data(using: .utf8)!
        let expected = "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c"
        XCTAssertEqual(input.sha256, expected)
    }

    // MARK: Propiedades del output

    /// El hash de dos inputs idénticos debe ser idéntico (determinismo).
    func test_sha256_isDeterministic() {
        let input = "SDPipeline Studio v1".data(using: .utf8)!
        XCTAssertEqual(input.sha256, input.sha256)
    }

    /// Un byte de diferencia en el input debe producir un hash completamente distinto.
    func test_sha256_avalancheEffect() {
        let a = "hello".data(using: .utf8)!
        let b = "hellp".data(using: .utf8)!
        XCTAssertNotEqual(a.sha256, b.sha256)
    }

    /// sha256 y sha256Hex deben ser idénticos en cualquier input.
    func test_sha256_aliasMatchesCanonical() {
        let inputs: [String] = ["", "a", "abc", "SDPipeline", "🎨"]
        for s in inputs {
            let data = s.data(using: .utf8)!
            XCTAssertEqual(data.sha256, data.sha256Hex, "Alias debe coincidir con sha256Hex para '\(s)'")
        }
    }

    /// El output sólo contiene caracteres hexadecimales lowercase.
    func test_sha256_outputIsLowercaseHex() {
        let data = "SDPipeline".data(using: .utf8)!
        let hex  = data.sha256
        let validChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hex.unicodeScalars.allSatisfy { validChars.contains($0) },
                      "sha256 debe contener sólo dígitos hexadecimales lowercase")
    }

    // =========================================================================
    // MARK: - 2. Data+Crypto — AES-GCM
    // =========================================================================

    /// Cifrar y descifrar con AES-GCM produce el plaintext original.
    func test_aesGCM_roundTrip() throws {
        let key       = SymmetricKey(size: .bits256)
        let plaintext = "SDPipeline Vault — datos privados 🔐".data(using: .utf8)!
        let encrypted = try plaintext.encryptedAESGCM(key: key)
        let decrypted = try encrypted.decryptedAESGCM(key: key)

        XCTAssertEqual(decrypted, plaintext)
    }

    /// Cifrar con una clave y descifrar con otra distinta debe fallar.
    func test_aesGCM_wrongKeyFails() throws {
        let key1      = SymmetricKey(size: .bits256)
        let key2      = SymmetricKey(size: .bits256)
        let plaintext = "datos secretos".data(using: .utf8)!
        let encrypted = try plaintext.encryptedAESGCM(key: key1)

        XCTAssertThrowsError(try encrypted.decryptedAESGCM(key: key2),
                             "Descifrar con clave incorrecta debe lanzar error")
    }

    /// Dos cifrados del mismo plaintext deben producir ciphertexts distintos (nonce aleatorio).
    func test_aesGCM_nonceIsRandom() throws {
        let key       = SymmetricKey(size: .bits256)
        let plaintext = "mismo texto".data(using: .utf8)!
        let enc1 = try plaintext.encryptedAESGCM(key: key)
        let enc2 = try plaintext.encryptedAESGCM(key: key)

        XCTAssertNotEqual(enc1, enc2, "El nonce aleatorio garantiza ciphertexts distintos")
    }

    /// Round-trip por la variante Base64.
    func test_aesGCM_base64RoundTrip() throws {
        let key       = SymmetricKey(size: .bits256)
        let plaintext = "ZeroKnowledgeLog entry".data(using: .utf8)!
        let base64    = try plaintext.encryptedBase64(key: key)
        let decrypted = try Data.decryptedBase64(base64, key: key)

        XCTAssertEqual(decrypted, plaintext)
    }

    /// Base64 inválido debe lanzar invalidBase64.
    func test_aesGCM_invalidBase64Throws() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try Data.decryptedBase64("esto-no-es-base64-válido!!!", key: key)) { error in
            XCTAssertTrue(error is CryptoVaultError)
        }
    }

    // =========================================================================
    // MARK: - 3. Data+Crypto — HKDF
    // =========================================================================

    /// Misma passphrase y misma salt producen la misma clave (determinismo).
    func test_hkdf_deterministicDerivation() {
        let k1 = SymmetricKey.derived(from: "passphrase-secreta", salt: Data("salt-fija".utf8))
        let k2 = SymmetricKey.derived(from: "passphrase-secreta", salt: Data("salt-fija".utf8))
        let bytes1 = k1.withUnsafeBytes { Data($0) }
        let bytes2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes1, bytes2)
    }

    /// Passphrases distintas producen claves distintas.
    func test_hkdf_differentPassphrasesProduceDifferentKeys() {
        let k1 = SymmetricKey.derived(from: "passphrase-A")
        let k2 = SymmetricKey.derived(from: "passphrase-B")
        let bytes1 = k1.withUnsafeBytes { Data($0) }
        let bytes2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(bytes1, bytes2)
    }

    /// La clave derivada tiene exactamente 32 bytes (AES-256).
    func test_hkdf_outputIs256Bits() {
        let key   = SymmetricKey.derived(from: "cualquier-passphrase")
        let bytes = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes.count, 32, "HKDF debe producir 32 bytes (AES-256)")
    }

    /// La clave derivada sin salt usa el salt por defecto del proyecto.
    func test_hkdf_defaultSaltIsDeterministic() {
        let k1 = SymmetricKey.derived(from: "test")
        let k2 = SymmetricKey.derived(from: "test")
        let bytes1 = k1.withUnsafeBytes { Data($0) }
        let bytes2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes1, bytes2)
    }

    // =========================================================================
    // MARK: - 4. PromptSafetyFilter
    // =========================================================================

    // MARK: Prompts permitidos

    func test_promptFilter_cleanPromptIsAllowed() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "elegant woman in evening gown, soft golden hour backlight",
            negative: "blurry, low quality"
        )
        if case .allowed = result { } else {
            XCTFail("Un prompt limpio debe retornar .allowed, obtuvo: \(result)")
        }
    }

    func test_promptFilter_emptyPromptIsAllowed() {
        let result = PromptSafetyFilter.validatePrompt(positive: "", negative: "")
        if case .allowed = result { } else {
            XCTFail("Prompt vacío debe ser .allowed")
        }
    }

    // MARK: Hard blocks

    func test_promptFilter_hardBlockedTermReturnsBlocked() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "photo of a child",
            negative: ""
        )
        if case .blocked = result { } else {
            XCTFail("'child' debe activar .blocked")
        }
    }

    func test_promptFilter_rapeTermReturnsBlocked() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "rape scene",
            negative: ""
        )
        if case .blocked = result { } else {
            XCTFail("'rape' debe activar .blocked")
        }
    }

    func test_promptFilter_incestTermReturnsBlocked() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "incest scenario",
            negative: ""
        )
        if case .blocked = result { } else {
            XCTFail("'incest' debe activar .blocked")
        }
    }

    func test_promptFilter_blockIsCaseInsensitive() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "CHILD portrait",
            negative: ""
        )
        if case .blocked = result { } else {
            XCTFail("El filtro debe ser case-insensitive")
        }
    }

    /// Un término bloqueado en el negativo también debe bloquear.
    func test_promptFilter_hardBlockInNegativeAlsoBlocks() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "beautiful portrait",
            negative: "loli style"
        )
        if case .blocked = result { } else {
            XCTFail("Término bloqueado en el prompt negativo también debe activar .blocked")
        }
    }

    // MARK: Soft flags

    func test_promptFilter_softFlagTermReturnsFlagged() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "very young looking woman",
            negative: ""
        )
        // "very young" está en softFlags
        if case .flagged = result { } else if case .blocked = result {
            // Si implementación futura lo eleva a blocked también es aceptable
        } else {
            XCTFail("'very young' debe retornar .flagged")
        }
    }

    // MARK: Blocked retorna los términos coincidentes

    func test_promptFilter_blockedContainsMatchedTerms() {
        let result = PromptSafetyFilter.validatePrompt(
            positive: "minor in swimwear",
            negative: ""
        )
        if case .blocked(_, let terms) = result {
            XCTAssertFalse(terms.isEmpty, "matchedTerms no debe estar vacío al bloquear")
        } else {
            XCTFail("Debe retornar .blocked")
        }
    }

    // MARK: JSON validation

    func test_promptFilter_validJSONSchemaIsAllowed() {
        let json: [String: Any] = [
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block":          true,
                "explicit_content_block":    true,
            ]
        ]
        let result = PromptSafetyFilter.validateJSON(json)
        if case .blocked = result {
            XCTFail("JSON con campos de seguridad correctos no debe bloquearse")
        }
    }

    func test_promptFilter_jsonWithMissingSafetyFieldIsFlagged() {
        let json: [String: Any] = [
            "prompt": "beautiful woman",
            "safety_compliance_layer": [
                "minor_protection_enforced": false,  // Campo incorrecto
                "sexual_act_block":          true,
                "explicit_content_block":    true,
            ]
        ]
        let result = PromptSafetyFilter.validateJSON(json)
        if case .allowed = result {
            XCTFail("Campo de seguridad con valor false debe generar advertencia")
        }
    }

    func test_promptFilter_jsonWithBlockedTextReturnsBlocked() {
        let json: [String: Any] = [
            "character_name": "innocent teen",
            "safety_compliance_layer": [
                "minor_protection_enforced": true,
                "sexual_act_block":          true,
                "explicit_content_block":    true,
            ]
        ]
        let result = PromptSafetyFilter.validateJSON(json)
        if case .blocked = result { } else {
            XCTFail("JSON con texto bloqueado debe retornar .blocked")
        }
    }

    // =========================================================================
    // MARK: - 5. Codable+Helpers
    // =========================================================================

    struct SampleModel: Codable, Equatable {
        let name:      String
        let createdAt: Date
        let value:     Int
    }

    func test_jsonEncoderPretty_roundTrip() throws {
        let date  = Date(timeIntervalSince1970: 1_700_000_000)
        let model = SampleModel(name: "SDPipeline", createdAt: date, value: 42)

        let data    = try JSONEncoder.pretty.encode(model)
        let decoded = try JSONDecoder.iso8601.decode(SampleModel.self, from: data)

        XCTAssertEqual(model, decoded)
    }

    func test_jsonEncoderPretty_outputIsReadable() throws {
        let model = SampleModel(name: "test", createdAt: Date(), value: 1)
        let data  = try JSONEncoder.pretty.encode(model)
        let json  = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\n"), "pretty encoder debe producir saltos de línea")
    }

    func test_jsonEncoderPretty_keysAreSorted() throws {
        let model = SampleModel(name: "z-name", createdAt: Date(), value: 99)
        let data  = try JSONEncoder.pretty.encode(model)
        let json  = String(data: data, encoding: .utf8) ?? ""

        // sortedKeys garantiza que "createdAt" aparezca antes que "name" antes que "value"
        let createdRange = json.range(of: "createdAt")
        let nameRange    = json.range(of: "name")
        let valueRange   = json.range(of: "value")

        XCTAssertNotNil(createdRange)
        XCTAssertNotNil(nameRange)
        XCTAssertNotNil(valueRange)

        if let c = createdRange, let n = nameRange, let v = valueRange {
            XCTAssertTrue(c.lowerBound < n.lowerBound, "'createdAt' debe aparecer antes que 'name'")
            XCTAssertTrue(n.lowerBound < v.lowerBound, "'name' debe aparecer antes que 'value'")
        }
    }

    func test_jsonDecoderISO8601_parsesDateCorrectly() throws {
        let json = """
        {"name":"test","createdAt":"2023-11-14T22:13:20Z","value":0}
        """.data(using: .utf8)!
        let model = try JSONDecoder.iso8601.decode(SampleModel.self, from: json)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(model.createdAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // =========================================================================
    // MARK: - 6. SeedManager.FavoriteSeed
    // =========================================================================

    @MainActor
    func test_favoriteSeed_codableRoundTrip() throws {
        let seed = SeedManager.FavoriteSeed(
            seed:       42_000_001,
            label:      "Seed dorado",
            promptHint: "elegant woman golden hour",
            tags:       ["favorito", "producción"]
        )

        let data    = try JSONEncoder.pretty.encode(seed)
        let decoded = try JSONDecoder.iso8601.decode(SeedManager.FavoriteSeed.self, from: data)

        XCTAssertEqual(decoded.seed,       seed.seed)
        XCTAssertEqual(decoded.label,      seed.label)
        XCTAssertEqual(decoded.promptHint, seed.promptHint)
        XCTAssertEqual(decoded.tags,       seed.tags)
    }

    /// Dos FavoriteSeeds con el mismo número de seed son iguales (Hashable por seed).
    @MainActor
    func test_favoriteSeed_equalityByeSeed() {
        let a = SeedManager.FavoriteSeed(seed: 12345, label: "A", promptHint: "")
        let b = SeedManager.FavoriteSeed(seed: 12345, label: "B", promptHint: "diferente")
        XCTAssertEqual(a, b, "FavoriteSeed se compara por seed, no por label")
    }

    @MainActor
    func test_favoriteSeed_differentSeedsAreNotEqual() {
        let a = SeedManager.FavoriteSeed(seed: 11111, label: "A", promptHint: "")
        let b = SeedManager.FavoriteSeed(seed: 22222, label: "A", promptHint: "")
        XCTAssertNotEqual(a, b)
    }

    /// El rating por defecto debe ser 0.
    @MainActor
    func test_favoriteSeed_defaultRatingIsZero() {
        let seed = SeedManager.FavoriteSeed(seed: 1, label: "test", promptHint: "")
        XCTAssertEqual(seed.rating, 0)
    }

    /// usageCount por defecto debe ser 1.
    @MainActor
    func test_favoriteSeed_defaultUsageCountIsOne() {
        let seed = SeedManager.FavoriteSeed(seed: 999, label: "test", promptHint: "")
        XCTAssertEqual(seed.usageCount, 1)
    }

    // =========================================================================
    // MARK: - 7. SDAPIRateLimiter.RequestPriority
    // =========================================================================

    func test_requestPriority_criticalIsLowestRawValue() {
        XCTAssertEqual(SDAPIRateLimiter.RequestPriority.critical.rawValue, 0)
    }

    func test_requestPriority_orderIsCorrect() {
        let critical = SDAPIRateLimiter.RequestPriority.critical
        let high     = SDAPIRateLimiter.RequestPriority.high
        let normal   = SDAPIRateLimiter.RequestPriority.normal
        let low      = SDAPIRateLimiter.RequestPriority.low

        XCTAssertTrue(critical < high,   "critical debe ser menor que high")
        XCTAssertTrue(high     < normal, "high debe ser menor que normal")
        XCTAssertTrue(normal   < low,    "normal debe ser menor que low")
    }

    func test_requestPriority_sortedArrayOrderedCorrectly() {
        let unsorted: [SDAPIRateLimiter.RequestPriority] = [.low, .critical, .normal, .high]
        let sorted   = unsorted.sorted()
        XCTAssertEqual(sorted, [.critical, .high, .normal, .low])
    }

    // =========================================================================
    // MARK: - 8. WildcardEngine — lógica de resolución
    // =========================================================================

    /// Un wildcard conocido debe ser reemplazado por un valor no vacío.
    @MainActor
    func test_wildcardEngine_resolvesKnownGroup() {
        let engine   = WildcardEngine.shared
        let resolved = engine.resolve("photo with __lighting__")

        XCTAssertFalse(resolved.contains("__lighting__"),
                       "El wildcard __lighting__ debe haber sido reemplazado")
        XCTAssertFalse(resolved.isEmpty)
    }

    /// Un wildcard sin grupo registrado debe permanecer sin cambios.
    @MainActor
    func test_wildcardEngine_unknownWildcardIsUnchanged() {
        let engine   = WildcardEngine.shared
        let input    = "photo with __grupo_inexistente__"
        let resolved = engine.resolve(input)

        XCTAssertEqual(resolved, input,
                       "Wildcard sin grupo debe dejarse tal cual en el prompt")
    }

    /// Un prompt sin wildcards debe permanecer idéntico.
    @MainActor
    func test_wildcardEngine_promptWithoutWildcardsIsUnchanged() {
        let engine  = WildcardEngine.shared
        let input   = "elegant woman, golden hour, cinematic"
        let output  = engine.resolve(input)
        XCTAssertEqual(input, output)
    }

    /// Múltiples wildcards en el mismo prompt deben resolverse todos.
    @MainActor
    func test_wildcardEngine_resolvesMultipleWildcards() {
        let engine   = WildcardEngine.shared
        let input    = "__lighting__ and __mood__"
        let resolved = engine.resolve(input)

        XCTAssertFalse(resolved.contains("__lighting__"))
        XCTAssertFalse(resolved.contains("__mood__"))
    }

    /// El mismo wildcard resuelto dos veces puede dar valores distintos (aleatoriedad).
    /// Este test verifica al menos que el mecanismo de selección aleatoria no crashea.
    @MainActor
    func test_wildcardEngine_resolveDoesNotCrash() {
        let engine = WildcardEngine.shared
        let groups = ["lighting", "mood", "camera", "style", "color_palette",
                      "weather", "time_of_day", "texture", "outfit",
                      "location_interior", "location_exterior", "composition"]
        for group in groups {
            let resolved = engine.resolve("__\(group)__")
            XCTAssertFalse(resolved.isEmpty, "Resolver __\(group)__ no debe dar string vacío")
        }
    }
}
