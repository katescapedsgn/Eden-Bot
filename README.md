# Eden 🐱

**A little pixel-art cat for your Mac.**

Eden is a playful macOS desktop companion that helps you open applications, navigate your workspace and interact with your favourite AI tools, all through a tiny lavender cat living on your desktop.

Originally forked from [Mochi](https://github.com/jessawolfe-ux/mochi) by [Jessa Wolfe](https://jessa.art/), Eden is customised and developed by [Kate Tacastacas](https://kateafable.com).

## Features

- **Desktop Cat**: A lavender pixel-art companion with idle, blink, sleeping, thinking and happy animations. Click to chat, drag to reposition and right-click for more options.
- **Quick Actions**: Use Open, Switch, Hide, Quit, Copy and Message buttons for guided desktop tasks.
- **Desktop Commands**: Type natural-language commands to open, switch, hide or gracefully quit apps, open common Finder folders, copy text or visit supported websites.
- **Guided AI Messaging**: Compose and copy a message, then open ChatGPT or Claude. You choose the conversation and send it yourself.
- **Codex Conversation Browser**: Browse existing local Codex threads and open them in Codex Desktop.

## How to Use

Click Eden to open the compact chat window. Choose a Quick Action or type a desktop command.

**Try asking Eden:**

- `Open Figma and Codex`
- `Switch to Safari`
- `Open Downloads`
- `Hide Spotify`
- `Copy text: hello world`
- `I want to send a message to ChatGPT`

Eden also has optional advanced controls for Claude Code and Codex CLI Terminal sessions.

**Note:** Guided Messaging prepares and copies your message, then opens ChatGPT or Claude. You'll select the conversation and send the message yourself.

## Installation

### Requirements

- macOS 13 or later
- Apple Swift command-line tools

You can build Eden without a signing certificate. The `Eden Local Signing` certificate is specific to the developer's Mac and is only needed for the default signed installation. Public users do not need it.

### Build

```bash
cd "$HOME/Documents/GitHub/Eden Bot"
bash scripts/install-local.sh --build-only
```

Without `Eden Local Signing`, build-only mode produces an unsigned app for validation.

### Install

For a local installation without the developer's certificate, explicitly choose ad hoc signing:

```bash
bash scripts/install-local.sh --install --ad-hoc
```

The installer asks you to confirm ad hoc signing and backs up an existing Eden app before replacing it. macOS may ask you to approve Accessibility or Automation permissions again after a rebuild.

If you have your own valid `Eden Local Signing` certificate and private key in Keychain, use the default signed installation:

```bash
bash scripts/install-local.sh --install
```

The installer builds and validates `Eden.app` but does not launch it automatically. Developer ID signing and notarisation are not currently provided.

**Migrating from Katescape:** If `~/Applications/Katescape.app` still exists, quit it and move it to a safe backup location before installing Eden. Keep the backup until Eden has been tested.

The original bundle identifier and legacy support paths are retained for compatibility. Avoid running the original `install.sh`, which manages the legacy Mochi setup.

## Credits & Licence

**Eden** is developed and customised by [Kate Tacastacas](https://kateafable.com).

Forked from **[Mochi](https://github.com/jessawolfe-ux/mochi)**, originally created by [Jessa Wolfe](https://jessa.art/).

The original MIT licence and copyright attribution are retained in [LICENSE](LICENSE).
