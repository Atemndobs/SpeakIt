class Speakit < Formula
  desc "Native macOS text-to-speech menu-bar app with high-quality voices"
  homepage "https://github.com/Atemndobs/SpeakIt"
  url "https://github.com/Atemndobs/SpeakIt.git", branch: "main"
  version "0.2.0"
  license "MIT"
  head "https://github.com/Atemndobs/SpeakIt.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["14.0", :build]
  depends_on "pipx" => :recommended

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    app = prefix/"SpeakIt.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath

    cp ".build/release/SpeakIt", app/"Contents/MacOS/SpeakIt"
    cp "scripts/Info.plist", app/"Contents/Info.plist"
    (app/"Contents/PkgInfo").write "APPL????"

    system "codesign", "--force", "--deep", "--sign", "-", app

    bin.write_exec_script app/"Contents/MacOS/SpeakIt"
  end

  def post_install
    target = "#{Dir.home}/Applications/SpeakIt.app"
    src = "#{prefix}/SpeakIt.app"
    unless File.exist?(target)
      FileUtils.mkdir_p File.dirname(target)
      FileUtils.ln_sf src, target
    end

    lsreg = "/System/Library/Frameworks/CoreServices.framework/Versions/A/" \
            "Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    system lsreg, "-f", src if File.executable?(lsreg)
  end

  def caveats
    <<~EOS
      SpeakIt.app is linked into ~/Applications.

      First launch:
        open ~/Applications/SpeakIt.app

      Grant Accessibility permission when prompted, then relaunch once.

      Optional: install Edge TTS for higher-quality voices:
        pipx install edge-tts

      Claude Code integration: install the companion plugin
        /plugin marketplace add Atemndobs/SpeakIt
        /plugin install claude-speak
    EOS
  end

  test do
    assert_predicate prefix/"SpeakIt.app/Contents/MacOS/SpeakIt", :executable?
  end
end
