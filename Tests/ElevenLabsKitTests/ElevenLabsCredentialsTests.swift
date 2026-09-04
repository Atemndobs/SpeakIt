import XCTest
@testable import ElevenLabsKit

/// Real Keychain round-trips against a throwaway service name, so the
/// developer's actual SpeakIt key is never touched.
final class ElevenLabsCredentialsTests: XCTestCase {

    private var credentials: ElevenLabsCredentials!
    private var service: String!

    override func setUp() {
        super.setUp()
        service = "com.atemkeng.speakit.tests.\(UUID().uuidString)"
        credentials = ElevenLabsCredentials(service: service, account: "api-key")
    }

    override func tearDown() {
        credentials.delete()
        super.tearDown()
    }

    /// The environment variable shadows the Keychain, which is what lets CI and
    /// the live test run without a stored credential. Skip the Keychain tests
    /// when it is set, otherwise they assert against the env value.
    private func skipIfEnvKeyPresent() throws {
        if ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?.isEmpty == false {
            throw XCTSkip("ELEVENLABS_API_KEY is set and shadows the Keychain")
        }
    }

    func testStoreAndRead() throws {
        try skipIfEnvKeyPresent()
        XCTAssertFalse(credentials.hasKey)
        XCTAssertTrue(credentials.store("xi-secret-value"))
        credentials.invalidateCache()
        XCTAssertEqual(credentials.apiKey, "xi-secret-value")
        XCTAssertTrue(credentials.hasKey)
    }

    func testOverwriteDoesNotDuplicateTheItem() throws {
        try skipIfEnvKeyPresent()
        XCTAssertTrue(credentials.store("first"))
        // SecItemAdd on an existing item returns errSecDuplicateItem rather
        // than overwriting, so this is the case that breaks a naive
        // implementation: the second key is silently dropped and the app keeps
        // authenticating with the old one.
        XCTAssertTrue(credentials.store("second"))
        credentials.invalidateCache()
        XCTAssertEqual(credentials.apiKey, "second")
    }

    func testDelete() throws {
        try skipIfEnvKeyPresent()
        credentials.store("value")
        XCTAssertTrue(credentials.delete())
        credentials.invalidateCache()
        XCTAssertNil(credentials.apiKey)
        XCTAssertFalse(credentials.hasKey)
    }

    func testDeletingWhenNothingIsStoredSucceeds() throws {
        try skipIfEnvKeyPresent()
        XCTAssertTrue(credentials.delete())
    }

    func testStoringBlankRemovesTheKey() throws {
        try skipIfEnvKeyPresent()
        credentials.store("value")
        XCTAssertTrue(credentials.store("   "))
        credentials.invalidateCache()
        XCTAssertNil(credentials.apiKey)
    }

    func testWhitespaceIsTrimmedOnStore() throws {
        try skipIfEnvKeyPresent()
        // Keys get pasted from a browser and arrive with a trailing newline.
        // An untrimmed key produces a 401 that looks like a bad key.
        credentials.store("  xi-padded-key\n")
        credentials.invalidateCache()
        XCTAssertEqual(credentials.apiKey, "xi-padded-key")
    }

    func testMaskedKeyHidesEverythingButTheLastFour() throws {
        try skipIfEnvKeyPresent()
        credentials.store("xi-abcdefghij9876")
        credentials.invalidateCache()
        let masked = try XCTUnwrap(credentials.maskedKey)
        XCTAssertTrue(masked.hasSuffix("9876"))
        XCTAssertFalse(masked.contains("abcdefghij"))
    }

    func testMaskedKeyIsNilWithNoKey() throws {
        try skipIfEnvKeyPresent()
        XCTAssertNil(credentials.maskedKey)
    }

    func testTwoServicesDoNotCollide() throws {
        try skipIfEnvKeyPresent()
        let other = ElevenLabsCredentials(
            service: "com.atemkeng.speakit.tests.\(UUID().uuidString)",
            account: "api-key"
        )
        defer { other.delete() }
        credentials.store("mine")
        other.store("theirs")
        credentials.invalidateCache()
        other.invalidateCache()
        XCTAssertEqual(credentials.apiKey, "mine")
        XCTAssertEqual(other.apiKey, "theirs")
    }

    func testEnvironmentVariableShadowsTheKeychain() {
        // Documents the precedence rather than asserting a value: whichever way
        // this machine is configured, the env var must win when set.
        let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        if let env, !env.isEmpty {
            XCTAssertEqual(credentials.apiKey, env.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            XCTAssertNil(credentials.apiKey)
        }
    }
}
