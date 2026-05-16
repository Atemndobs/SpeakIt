cask "speakit" do
  version "0.2.2"
  sha256 "c577f9563ad40d68baf446f97cdc3d8fb95c1a4ce83321e8d5968c78b4294266"

  url "https://github.com/Atemndobs/SpeakIt/releases/download/v#{version}/SpeakIt-#{version}.zip"
  name "SpeakIt"
  desc "Native macOS text-to-speech menu-bar app with high-quality voices"
  homepage "https://github.com/Atemndobs/SpeakIt"

  depends_on macos: ">= :sonoma"
  depends_on formula: "pipx"

  app "SpeakIt.app"

  # Install edge-tts via pipx so the Microsoft Edge Neural voices work
  # out of the box. Non-fatal if it's already installed or pipx fails —
  # SpeakIt falls back to the offline Apple Speech engine either way.
  postflight do
    pipx = "#{HOMEBREW_PREFIX}/bin/pipx"
    if File.executable?(pipx)
      system_command pipx, args: ["install", "edge-tts"], must_succeed: false
    end
  end

  zap trash: [
    "~/Library/Preferences/com.atem.SpeakIt.plist",
    "~/Library/Application Scripts/com.atem.SpeakIt",
    "~/Library/Containers/com.atem.SpeakIt",
  ]

  caveats <<~EOS
    First launch:
      open -a SpeakIt

    Grant Accessibility permission when prompted, then relaunch once.

    Edge TTS (high-quality neural voices) was installed automatically via pipx.
    To upgrade later:
      pipx upgrade edge-tts

    Claude Code integration: install the companion plugin
      /plugin marketplace add Atemndobs/SpeakIt
      /plugin install claude-speak
  EOS
end
