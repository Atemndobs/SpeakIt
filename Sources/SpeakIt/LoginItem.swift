import ServiceManagement
import SwiftUI

/// Wraps macOS's modern login-item API (`SMAppService.mainApp`, macOS 13+).
/// Toggling registers/unregisters the bundle so it auto-launches on user login.
/// The app must be code-signed (any cert — including our self-signed identity).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published var isEnabled: Bool

    private init() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LoginItem] toggle failed: \(error)")
        }
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }
}
