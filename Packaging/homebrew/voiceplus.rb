cask "voiceplus" do
  version "1.8.0"
  sha256 "caa3009dcd628d740ee9c667b16970c5f300aaa47b9396b79051006ef3b85185"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V3-w01%2Fv1.8.0/VoicePlus_V3-w01_1.8.0.dmg"
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
