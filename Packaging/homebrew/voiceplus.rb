cask "voiceplus" do
  version "1.4.0"
  sha256 "98ec9cf4367b0e8ee1be0f16e5ae902c6b3bce8bae472603ad79a2826e8e5ecc"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-4%2Fv1.4.0/VoicePlus_4_1.4.0.dmg"
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
