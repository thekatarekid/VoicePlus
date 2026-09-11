cask "voiceplus" do
  version "1.9.0"
  sha256 "91caf4a95181be3dccf9c143398a8de8fda3126c5bc87c74ae312dafb0c557e2"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V3-w2%2Fv1.9.0/VoicePlus_V3-w2_1.9.0.dmg"
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
