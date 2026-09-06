cask "voiceplus" do
  version "1.6.6"
  sha256 "736716ea540a74154573e6cc287ca8bf31411fd905987403ce5c6c13f31dd058"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-6%2Fv1.6.6/VoicePlus_6_1.6.6.dmg"
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
