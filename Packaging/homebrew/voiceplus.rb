cask "voiceplus" do
  version "1.6.5"
  sha256 "6f4ded76ebe428b2bb56e73482d4b3d66b9f2a142db0a57509e6930f7b66dd03"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-6%2Fv1.6.5/VoicePlus_6_1.6.5.dmg"
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
