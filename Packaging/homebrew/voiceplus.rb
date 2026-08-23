cask "voiceplus" do
  version "1.3.0"
  sha256 "5344f3e9c8f90e7d012780af96d9c8ad3850cc11998901219f66a3c178da5969"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-3%2Fv1.3.0/VoicePlus_3_1.3.0.dmg"
  name "VoicePlus"
  desc "Local-first voice dictation for macOS"
  homepage "https://github.com/thekatarekid/VoicePlus"

  depends_on macos: ">= :sonoma"

  app "VoicePlus.app"

  zap trash: [
    "~/Library/Application Support/VoicePlus",
    "~/Library/Preferences/in.adityakatare.voiceplus.plist",
  ]

  caveats <<~EOS
    VoicePlus is ad-hoc signed (not notarized). On first launch use
    right-click > Open, then grant Microphone and Accessibility access.
  EOS
end
