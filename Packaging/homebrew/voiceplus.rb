cask "voiceplus" do
  version "1.6.1"
  sha256 "020958a94e1af2b51831a0ece5b1d11c09e89d2aaaf2020f821ccdddd134d612"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-6%2Fv1.6.1/VoicePlus_6_1.6.1.dmg"
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
