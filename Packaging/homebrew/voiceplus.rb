cask "voiceplus" do
  version "1.11.1"
  sha256 "8a2edfd55e788854c72f39361bb828787b25ae23bdbbfa0a387aa46cedcbf7a5"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V4-w1%2Fv1.11.1/VoicePlus_V4-w1_1.11.1.dmg"
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
