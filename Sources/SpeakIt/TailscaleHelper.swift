import Foundation

/// Thin wrapper around the `tailscale` CLI for MagicDNS lookup and the
/// `tailscale serve` HTTPS proxy.
enum TailscaleHelper {
    static func binaryPath() -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Best-effort MagicDNS hostname (e.g. "my-mac.tail-scale.ts.net"). Nil
    /// if Tailscale isn't installed, MagicDNS isn't enabled, or status fails.
    static func magicDNSName() -> String? {
        guard let bin = binaryPath() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "--json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let selfNode = root["Self"] as? [String: Any],
            let dnsRaw = selfNode["DNSName"] as? String
        else { return nil }

        var dns = dnsRaw
        if dns.hasSuffix(".") { dns.removeLast() }
        return dns.isEmpty ? nil : dns
    }

    /// Run `tailscale serve --bg --https=443 http://localhost:<port>`.
    /// Returns nil on success or a stderr message describing the failure.
    @discardableResult
    static func enableServeHTTPS(targetPort: Int) -> String? {
        guard let bin = binaryPath() else { return "Tailscale CLI not found" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve", "--bg", "--https=443", "http://localhost:\(targetPort)"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { return "Failed to launch: \(error.localizedDescription)" }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return nil }
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stderr + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func disableServeHTTPS() {
        guard let bin = binaryPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve", "--https=443", "off"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}
