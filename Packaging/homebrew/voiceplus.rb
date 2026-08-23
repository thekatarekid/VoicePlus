cask "voiceplus" do
  version "1.1.0"
  sha256 "451351335368748bc27ac7dffa2659d259332ffe9e3baef5fd138617d2e3db31"

  url "https://github.com/thekatarekid/VoicePlus/releases/download/release%2Fphase-1.5%2Fv1.1.0/VoicePlus_1.5_1.1.0.dmg"
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
