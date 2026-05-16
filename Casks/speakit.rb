cask "speakit" do
  version "0.2.0"
  sha256 "10a099ca2ce48149db0cc35bbf34a1c764b7b06909fd6c2a1b457cfb77a109e6"

  url "https://github.com/Atemndobs/SpeakIt/releases/download/v#{version}/SpeakIt-#{version}.zip"
  name "SpeakIt"
  desc "Native macOS text-to-speech menu-bar app with high-quality voices"
  homepage "https://github.com/Atemndobs/SpeakIt"

  depends_on macos: ">= :sonoma"

  app "SpeakIt.app"

  zap trash: [
    "~/Library/Preferences/com.atem.SpeakIt.plist",
    "~/Library/Application Scripts/com.atem.SpeakIt",
    "~/Library/Containers/com.atem.SpeakIt",
  ]

  caveats <<~EOS
    First launch:
      open -a SpeakIt

    Grant Accessibility permission when prompted, then relaunch once.

    Optional: install Edge TTS for higher-quality voices:
      brew install pipx && pipx install edge-tts

    Claude Code integration: install the companion plugin
      /plugin marketplace add Atemndobs/SpeakIt
      /plugin install claude-speak
  EOS
end
