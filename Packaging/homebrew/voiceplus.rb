cask "voiceplus" do
  version "1.6.4"
  sha256 "731be2bf6095d800e1a29a047ca8cfe56be17f32de36a8faadd777c5bbe5e248"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-6%2Fv1.6.4/VoicePlus_6_1.6.4.dmg"
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
