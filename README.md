# Eden 🐱

**A little pixel-art cat for your Mac.**

Eden is a playful macOS desktop companion that helps you open applications, navigate your workspace and interact with your favourite AI tools, all through a tiny lavender cat living on your desktop.

Originally forked from [Mochi](https://github.com/jessawolfe-ux/mochi) by [Jessa Wolfe](https://jessa.art/), Eden is customised and developed by [Kate Tacastacas](https://kateafable.com).

## Features

- **Desktop Cat**: A lavender pixel-art companion with expressive animations. Click to chat, drag to reposition and right-click for more options.
- **App Launcher**: Open installed Mac applications using natural-language commands, such as `Open Figma and Codex`.
- **Guided AI Messaging**: Compose messages for ChatGPT or Claude, then open the selected application or website to send them.
- **Codex Conversation Browser**: Browse local Codex conversations and open them in Codex Desktop.

## How to Use

Click Eden to open the compact chat window and type a command.

**Try asking Eden:**

- `Open Figma`
- `Launch Codex and Claude`
- `Show my Codex conversations`
- `I want to send a message to ChatGPT`

Eden also has optional advanced controls for Claude Code and Codex CLI Terminal sessions.

**Note:** Guided Messaging prepares and copies your message, then opens ChatGPT or Claude. You'll select the conversation and send the message yourself.

## Installation

### Requirements

- macOS 13 or later
- Apple Swift command-line tools
- A suitable signing identity for signed installation, or explicit ad hoc signing for local testing

### Build

```bash
cd "$HOME/Documents/GitHub/Eden Bot"
bash scripts/install-local.sh --build-only
```

### Install

```bash
bash scripts/install-local.sh --install
```

For local ad hoc signing:

```bash
bash scripts/install-local.sh --install --ad-hoc
```

The installer builds and validates `Eden.app` but does not launch it automatically.

**Migrating from Katescape:** If `~/Applications/Katescape.app` still exists, quit it and move it to a safe backup location before installing Eden. Keep the backup until Eden has been tested.

The original bundle identifier and legacy support paths are retained for compatibility. Avoid running the original `install.sh`, which manages the legacy Mochi setup.

## Credits & Licence

**Eden** is developed and customised by [Kate Tacastacas](https://kateafable.com).

Forked from **[Mochi](https://github.com/jessawolfe-ux/mochi)**, originally created by [Jessa Wolfe](https://jessa.art/).

The original MIT licence and copyright attribution are retained in [LICENSE](LICENSE).
