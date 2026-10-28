# Eden 🐱

Eden is a pixel-art macOS desktop companion featuring a lavender cat. Click the cat to open a compact chat, use its universal macOS app launcher with commands such as “Open Figma and Codex,” or browse local Codex threads. Advanced Claude Code and Codex CLI Terminal controls remain available from the pet and menu bar menus.

Guided messaging for ChatGPT and Claude helps you compose a message, copies it to the clipboard after confirmation, and opens the destination app or website. You choose the conversation, paste, and send it yourself. Eden does not directly send to existing ChatGPT or Claude conversations.

The app lives in this repository at `~/Documents/GitHub/Eden Bot`. Internal Swift names, Claude hook paths, and `~/Library/Application Support/Mochi` remain unchanged so existing data and integrations continue to work.

## Build Eden

Requires macOS 13 or later, Apple's Swift command line tools, and the existing `Mochi Local Signing` identity for a signed installation. From this repository:

```bash
cd "$HOME/Documents/GitHub/Eden Bot"
bash scripts/install-local.sh --build-only
```

This builds and validates `build/Eden.app` without installing or opening it. The script keeps the bundle identifier `io.github.jessawolfe.mochi` and uses the existing signing identity when available. It requires `assets/branding/Eden.icns` and installs that icon into the app bundle. See [branding/README.md](branding/README.md).

## Install Eden when ready

The local installer never launches the app. It refuses to install while `~/Applications/Katescape.app` exists because Eden uses the same bundle identifier. First quit Katescape, then move its app bundle to a backup location of your choosing. Keep that backup until Eden has been tested. Do not run the legacy `install.sh`; it belongs to the original Mochi installer and would otherwise manage Claude hooks and user settings.

After retiring the old app bundle, run:

```bash
cd "$HOME/Documents/GitHub/Eden Bot"
bash scripts/install-local.sh --install
```

The script stages and verifies `~/Applications/Eden.app`. If an Eden.app already exists, it requires interactive confirmation and backs up the existing app before replacement. It does not remove Katescape.app, change account settings, or launch Eden.

If no valid `Mochi Local Signing` identity exists, `--install` refuses the build. You can explicitly choose `bash scripts/install-local.sh --install --ad-hoc`; the script asks for a second confirmation. Ad hoc signing can cause macOS to ask for Automation or Accessibility permissions again after future rebuilds. The local builder does not create certificates or alter Keychain.

macOS may still show an existing Login Item or privacy permission under the old name until the system refreshes its registration. The bundle identifier and signing identity remain unchanged. Check **System Settings → General → Login Items** after manually switching apps, and keep only the desired entry enabled.

## Use

- Click Eden to open or close the chat; drag the cat to reposition it; right-click for the menu.
- Type an explicit launcher command such as `Open Figma` or `Show my Codex conversations`.
- Type `Message Claude` or `Message ChatGPT` for a guided copy-and-open flow. Eden does not claim to send those messages automatically.
- Use **Advanced** for optional Terminal provider and destination controls. These require an existing, verified CLI session.

The legacy data directory at `~/Library/Application Support/Mochi` and the existing Claude hooks are intentionally unchanged by this rename.

## Credits and licence

Created and developed by [Kate Tacastacas](https://kateafable.com).

Based on the [original Mochi project](https://github.com/jessawolfe-ux/mochi), created by [Jessa Wolfe](https://jessa.art/). The repository retains the original MIT licence and Jessa Wolfe's copyright notice in [LICENSE](LICENSE).
