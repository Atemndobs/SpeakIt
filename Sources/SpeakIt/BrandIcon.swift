import AppKit
import SwiftUI

/// Real application icons, read from the apps installed on this Mac.
///
/// The menu names other products (Claude Code, Codex, Tailscale) and a generic
/// glyph next to those rows reads as decoration. The actual mark reads as
/// identification.
///
/// Loaded through `NSWorkspace` rather than bundled as artwork, for three
/// reasons. This repository is public and shipping other companies' logos into
/// it is a trademark question nobody needs. The icon always matches the version
/// of the app the user actually has, including whatever it looks like after the
/// next redesign. And a row whose app is not installed falls back on its own,
/// which is the correct behaviour anyway: there is no point showing the Codex
/// mark to someone who has never installed it.
enum BrandIcon {

    /// Bundle identifiers, most preferred first. Several products ship under
    /// more than one id depending on how they were installed, and the id does
    /// not always match the name: the ChatGPT desktop app registers as
    /// `com.openai.codex` on this machine.
    enum Brand {
        static let claude = ["com.anthropic.claudefordesktop"]
        static let openAI = ["com.openai.codex", "com.openai.chatgpt"]
        static let tailscale = ["io.tailscale.ipn.macos", "com.tailscale.ipn.macsys"]
        static let edge = ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta"]
    }

    /// Cached because this runs inside a SwiftUI body: the menu re-renders on
    /// every state change, and hitting Launch Services each time would put a
    /// disk lookup in the render path.
    private static var cache: [String: NSImage?] = [:]

    static func image(_ bundleIDs: [String]) -> NSImage? {
        let key = bundleIDs.joined(separator: "|")
        if let cached = cache[key] { return cached }

        var found: NSImage?
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                found = NSWorkspace.shared.icon(forFile: url.path)
                break
            }
        }
        cache[key] = found
        return found
    }

    static func isInstalled(_ bundleIDs: [String]) -> Bool { image(bundleIDs) != nil }
}

/// A row label showing a real app icon when that app is installed, and an SF
/// Symbol when it is not.
///
/// `symbol` is not a placeholder to be tolerated: it is what most users with a
/// normal set of apps will actually see, so it has to stand on its own.
struct BrandLabel: View {
    let title: String
    var bundleIDs: [String] = []
    let symbol: String
    var size: CGFloat = 14

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let icon = BrandIcon.image(bundleIDs) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: symbol)
            }
        }
    }
}
