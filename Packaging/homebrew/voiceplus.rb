cask "voiceplus" do
  version "1.11.0"
  sha256 "e80a1b58715c68f31661886001899246914657f03cc7ca02477caf618165cf92"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V4-w1%2Fv1.11.0/VoicePlus_V4-w1_1.11.0.dmg"
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
