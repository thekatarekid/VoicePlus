cask "voiceplus" do
  version "1.6.0"
  sha256 "66ae1e52b469a2b65a85761f16e5256865d7e707eed5bc68ae9ee1305310a1af"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-6%2Fv1.6.0/VoicePlus_6_1.6.0.dmg"
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
