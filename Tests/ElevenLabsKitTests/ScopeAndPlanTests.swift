import XCTest
@testable import ElevenLabsKit

/// Both cases in this file were discovered by the first live API run, not by
/// any stub. That is the argument for having live tests at all: a mocked client
/// only ever proves the code matches my beliefs about the API.
final class ScopeAndPlanTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func api() -> ElevenLabsAPI {
        ElevenLabsAPI(session: StubURLProtocol.session()) { "test-key" }
    }

    private static let missingPermissionBody = #"{"detail":{"type":"authentication_error","code":"unauthorized","message":"The API key you used is missing the permission voices_read to execute this operation.","status":"missing_permissions"}}"#

    private static let paidPlanBody = #"{"detail":{"type":"payment_required","code":"paid_plan_required","message":"Free users cannot use library voices via the API. Please upgrade your subscription to use this voice.","status":"payment_required"}}"#

    /// A scoped key missing a permission arrives as a 401 with the same shape
    /// as a rejected key. Reporting it as "ElevenLabs rejected the API key"
    /// sends someone off to revoke and recreate a credential that was fine.
    func testMissingPermissionIsNotReportedAsABadKey() async {
        StubURLProtocol.handler = { _ in .json(Self.missingPermissionBody, status: 401) }
        do {
            _ = try await api().synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected missingPermission")
        } catch let error as ElevenLabsAPI.APIError {
            guard case .missingPermission(let scope) = error else {
                return XCTFail("expected missingPermission, got \(error)")
            }
            XCTAssertEqual(scope, "voices_read")
            // The message has to name the scope, otherwise it is no more
            // actionable than the generic rejection it replaced.
            XCTAssertTrue(error.errorDescription?.contains("voices_read") ?? false)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAGenuinelyBadKeyIsStillUnauthorized() async {
        // The discrimination has to work in both directions.
        StubURLProtocol.handler = { _ in .json(#"{"detail":"invalid api key"}"#, status: 401) }
        do {
            _ = try await api().synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected unauthorized")
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A free account cannot use shared library voices through the API, and it
    /// arrives as a 402 rather than a 401.
    func testPaidPlanRequiredIsItsOwnCase() async {
        StubURLProtocol.handler = { _ in .json(Self.paidPlanBody, status: 402) }
        do {
            _ = try await api().synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected paidPlanRequired")
        } catch let error as ElevenLabsAPI.APIError {
            guard case .paidPlanRequired(let message) = error else {
                return XCTFail("expected paidPlanRequired, got \(error)")
            }
            XCTAssertTrue(message.contains("library voices"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNeitherPlanNorScopeErrorsAreRetried() {
        // No number of attempts grants a scope or upgrades a plan. Retrying
        // would spend the listener's time on a certainty.
        XCTAssertFalse(ElevenLabsAPI.APIError.missingPermission(scope: "voices_read").isRetryable)
        XCTAssertFalse(ElevenLabsAPI.APIError.paidPlanRequired("upgrade").isRetryable)
    }

    func testScopeParsingDegradesRatherThanMisreporting() {
        // If the wording changes, still report a scope problem rather than
        // falling back to "bad key", which is the misleading outcome.
        let vague = Data(#"{"detail":{"status":"missing_permissions","message":"nope"}}"#.utf8)
        XCTAssertEqual(ElevenLabsAPI.missingScope(from: vague), "required")

        // And a real rejection must not be mistaken for a scope problem.
        XCTAssertNil(ElevenLabsAPI.missingScope(from: Data(#"{"detail":"bad key"}"#.utf8)))
        XCTAssertNil(ElevenLabsAPI.missingScope(from: Data()))
    }

    func testScopeIsParsedFromTheRealMessageShape() {
        let body = Data(Self.missingPermissionBody.utf8)
        XCTAssertEqual(ElevenLabsAPI.missingScope(from: body), "voices_read")
    }
}

/// The environment variable silently overriding the Keychain caused a real
/// confusing failure: the app reported a rejected key while a correct one sat
/// in the Keychain unused.
final class CredentialSourceTests: XCTestCase {

    func testSourceIsEnvironmentWhenTheVariableIsSet() throws {
        try XCTSkipIf(
            (ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "").isEmpty,
            "needs ELEVENLABS_API_KEY set to exercise this path"
        )
        let creds = ElevenLabsCredentials(service: "test.\(UUID().uuidString)", account: "k")
        XCTAssertEqual(creds.source, .environment)
        XCTAssertTrue(creds.source.overridesKeychain)
    }

    func testSourceIsNoneWithNoKeyAnywhere() throws {
        try XCTSkipIf(
            (ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "").isEmpty == false,
            "environment key shadows the Keychain, so this path is unreachable here"
        )
        let creds = ElevenLabsCredentials(service: "test.\(UUID().uuidString)", account: "k")
        XCTAssertEqual(creds.source, .none)
        XCTAssertFalse(creds.source.overridesKeychain)
    }

    func testKeychainSourceIsNotFlaggedAsAnOverride() {
        XCTAssertFalse(ElevenLabsCredentials.Source.keychain.overridesKeychain)
        XCTAssertFalse(ElevenLabsCredentials.Source.none.overridesKeychain)
    }

    func testSourceDescriptionsAreHumanReadable() {
        // These strings go straight into a user-facing error, so they have to
        // read as a sentence fragment, not as an enum case name.
        XCTAssertTrue(ElevenLabsCredentials.Source.environment.rawValue.contains("environment variable"))
        XCTAssertTrue(ElevenLabsCredentials.Source.keychain.rawValue.contains("Keychain"))
    }
}
