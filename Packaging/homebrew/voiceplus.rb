cask "voiceplus" do
  version "1.10.0"
  sha256 "1dba134819bea6e83e0adf5b4de2f23375c94aaf5bb2192c144794cbc6392c24"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-V3-w34%2Fv1.10.0/VoicePlus_V3-w34_1.10.0.dmg"
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
