cask "voiceplus" do
  version "1.11.2"
  sha256 "86d8cdd5c4f2914e36dc7748ea274ebfe3a436c3e27bb95d52ae522713b37ae9"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V4-w1%2Fv1.11.2/VoicePlus_V4-w1_1.11.2.dmg"
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
