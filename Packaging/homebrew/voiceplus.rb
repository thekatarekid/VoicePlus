cask "voiceplus" do
  version "1.0.0"
  sha256 "6ce21d6cecb061bbc18308c28ffbb4d7a0fe236f19a7fa0edef116cc6620e0f9"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-1%2Fv1.0.0/VoicePlus_1_1.0.0.dmg"
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
