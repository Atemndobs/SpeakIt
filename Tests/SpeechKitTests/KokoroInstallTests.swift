import XCTest
@testable import SpeechKit

final class KokoroInstallTests: XCTestCase {

    private let install = KokoroInstall(root: URL(fileURLWithPath: "/home/.speakit/kokoro"))

    private func exists(_ present: Set<String>) -> (URL) -> Bool {
        { present.contains($0.lastPathComponent) }
    }

    private var everything: Set<String> { ["python", "kokoro_daemon.py", "kokoro.onnx", "voices.bin"] }

    func testLayoutMatchesTheSetupScript() {
        XCTAssertEqual(install.python.path, "/home/.speakit/kokoro/venv/bin/python")
        XCTAssertEqual(install.daemon.path, "/home/.speakit/kokoro/kokoro_daemon.py")
        XCTAssertEqual(install.model.path, "/home/.speakit/kokoro/kokoro.onnx")
        XCTAssertEqual(install.voices.path, "/home/.speakit/kokoro/voices.bin")
    }

    func testStandardRootIsUnderTheHomeDirectory() {
        let standard = KokoroInstall.standard(home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(standard.root.path, "/Users/someone/.speakit/kokoro")
    }

    func testCompleteInstallIsReady() {
        XCTAssertEqual(install.status(exists: exists(everything)), .ready)
        XCTAssertTrue(install.isReady(exists: exists(everything)))
    }

    func testNothingPresentReadsAsNotInstalled() {
        // Distinct from a broken install: the fix is "run setup", not
        // "something went wrong".
        XCTAssertEqual(install.status(exists: exists([])), .notInstalled)
    }

    func testPartialInstallNamesWhatIsMissing() {
        // The interesting case: setup ran, then the model download was
        // interrupted. Reporting a bare "not installed" here sends people
        // looking in the wrong place.
        let status = install.status(exists: exists(["python", "kokoro_daemon.py"]))
        XCTAssertEqual(status, .incomplete(missing: ["model weights", "voice pack"]))
    }

    func testMissingVoicePackAloneIsStillIncomplete() {
        let status = install.status(exists: exists(everything.subtracting(["voices.bin"])))
        XCTAssertEqual(status, .incomplete(missing: ["voice pack"]))
    }

    func testBundledDaemonOverridesTheHomeCopy() {
        // An app update ships a new daemon script inside SpeakIt.app without
        // making the user re-download 350 MB of weights.
        let bundled = URL(fileURLWithPath: "/Applications/SpeakIt.app/Contents/Resources/kokoro_daemon.py")
        let overridden = install.withDaemon(bundled)

        XCTAssertEqual(overridden.daemonScript, bundled)
        XCTAssertEqual(install.daemonScript, install.daemon, "the original must be unchanged")

        // Ready even though no daemon script sits in the home directory.
        let present: Set<String> = ["python", "kokoro.onnx", "voices.bin", "kokoro_daemon.py"]
        XCTAssertEqual(overridden.status(exists: exists(present)), .ready)
    }

    func testOverrideIsCheckedRatherThanAssumedPresent() {
        let missing = URL(fileURLWithPath: "/nowhere/kokoro_daemon.py")
        let overridden = install.withDaemon(missing)
        let present: Set<String> = ["python", "kokoro.onnx", "voices.bin"]
        XCTAssertEqual(
            overridden.status(exists: { $0 != missing && present.contains($0.lastPathComponent) }),
            .incomplete(missing: ["synthesis daemon"])
        )
    }

    func testEveryFailureStateExplainsTheNextStep() {
        XCTAssertNil(KokoroInstall.Status.ready.explanation)

        for status: KokoroInstall.Status in [.notInstalled, .incomplete(missing: ["voice pack"])] {
            let explanation = status.explanation
            XCTAssertNotNil(explanation)
            XCTAssertTrue(explanation!.contains("kokoro-setup.sh"),
                          "the message should name the command that fixes it")
        }
    }
}
