# Cask template for the own tap tlgnkl/homebrew-tap (Casks/perekey.rb).
# Replace version and sha256 per release; see packaging/README.md.
cask "perekey" do
  version "0.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_DMG"

  url "https://github.com/tlgnkl/perekey/releases/download/v#{version}/Perekey-#{version}.dmg"
  name "Perekey"
  desc "Keyboard layout switcher that fixes text typed in the wrong layout"
  homepage "https://tlgnkl.github.io/perekey/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true # Sparkle updates the app itself
  depends_on macos: ">= :sonoma"

  app "Perekey.app"

  zap trash: [
    "~/Library/Application Support/Perekey",
    "~/Library/Preferences/app.perekey.Perekey.plist",
    "~/Library/Caches/app.perekey.Perekey",
    "~/Library/Logs/Perekey",
    "~/Library/Saved Application State/app.perekey.Perekey.savedState",
  ]
end
