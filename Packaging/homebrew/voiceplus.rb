cask "voiceplus" do
  version "1.2.0"
  sha256 "ff450a8ca29c89f0072fa45185e602e9c4ab05dda2c3781ce177f945893d9840"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-2%2Fv1.2.0/VoicePlus_2_1.2.0.dmg"
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
