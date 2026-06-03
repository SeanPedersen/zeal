#!/usr/bin/env bash
# ZEAL installer for macOS

set -e

ZEAL_DIR="$HOME/.zeal"
ZEAL_FILE="$ZEAL_DIR/zeal.zsh"
ZSHRC="$HOME/.zshrc"
NERD_FONT="font-meslo-lg-nerd-font"

info()  { printf "\033[1;34m==>\033[0m %s\n" "$1"; }
ok()    { printf "\033[1;32m==>\033[0m %s\n" "$1"; }
skip()  { printf "\033[1;33m==>\033[0m %s\n" "$1"; }
err()   { printf "\033[1;31m==>\033[0m %s\n" "$1" >&2; }

if [[ "$(uname)" != "Darwin" ]]; then
  err "This installer is for macOS only."
  exit 1
fi

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
else
  ok "Homebrew already installed"
fi

# --- ZSH ---
if ! command -v zsh &>/dev/null; then
  info "Installing zsh..."
  brew install zsh
else
  ok "zsh already installed"
fi

# --- Nerd Font ---
if brew list --cask "$NERD_FONT" &>/dev/null; then
  ok "Nerd Font already installed"
else
  info "Installing MesloLG Nerd Font..."
  brew install --cask "$NERD_FONT"
  ok "Nerd Font installed — set it as your terminal font"
fi

# --- Set default shell ---
ZSH_PATH="$(command -v zsh)"
if ! grep -qF "$ZSH_PATH" /etc/shells 2>/dev/null; then
  info "Adding $ZSH_PATH to /etc/shells..."
  echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
fi

CURRENT_SHELL="$(dscl . -read /Users/"$USER" UserShell | awk '{print $2}')"
if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
  info "Setting zsh as default shell..."
  chsh -s "$ZSH_PATH"
else
  ok "zsh is already the default shell"
fi

# --- Install ZEAL ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/zeal.zsh"

if [[ ! -f "$SOURCE_FILE" ]]; then
  info "Downloading zeal.zsh..."
  mkdir -p "$ZEAL_DIR"
  curl -fsSL -o "$ZEAL_FILE" "https://raw.githubusercontent.com/SeanPedersen/zeal/refs/heads/main/zeal.zsh"
else
  info "Installing zeal.zsh..."
  mkdir -p "$ZEAL_DIR"
  cp "$SOURCE_FILE" "$ZEAL_FILE"
fi
ok "Installed to $ZEAL_FILE"

# --- Source from .zshrc ---
SOURCE_LINE="source $ZEAL_FILE"
if [[ -f "$ZSHRC" ]] && grep -qF "$SOURCE_LINE" "$ZSHRC"; then
  skip "Already sourced in $ZSHRC"
else
  info "Adding to $ZSHRC..."
  {
    echo ""
    echo "# ZEAL: smart & fast ZSH config"
    echo "$SOURCE_LINE"
  } >> "$ZSHRC"
  ok "Added to $ZSHRC"
fi

echo ""
ok "ZEAL installed! Restart your terminal or run: source $ZEAL_FILE"
