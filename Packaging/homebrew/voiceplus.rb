cask "voiceplus" do
  version "0.0.1"
  sha256 "78478d0af03229f2882a373e538210939bd86a647f2afb1c67e7147e139f7515"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-0%2Fv0.0.1/VoicePlus_0_0.0.1.dmg"
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
