# ZEAL: smart & fast ZSH config

## ZEAL Features
- Contextual auto-suggestion based on command history of CWD + global history (prio: 1. prefix, 2. substring)
  - smart rejection of commands using relative paths into global history
- Custom CTRL + R: show command history of CWD + dual search (contextual + global history)
- Agnoster inspired theme (showing current git branch + status + commits)
  - runs git fetch (async) on first cd into a git repo (to show new commits from remote)
- Shortens long paths (to first char)
- Print execution timestamp + runtime in secs of last command


https://github.com/user-attachments/assets/a89d975d-e0e7-4bf8-b050-e73b2621d48f


## Install ZEAL

### Quick Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/SeanPedersen/zeal/refs/heads/main/mac-install.sh | bash
```

Or clone and run locally:
```bash
git clone https://github.com/SeanPedersen/zeal.git
cd zeal
bash mac-install.sh
```

The installer will:
- Install zsh, git, and Nerd Font if missing (via Homebrew)
- Set zsh as your default shell
- Install zeal.zsh to `~/.zeal/`
- Add `source ~/.zeal/zeal.zsh` to your `.zshrc`

### Manual Install

- Install ZSH
  - Debian: ```sudo apt install zsh``` Arch: ```pacman -S zsh```
  - MacOS: ```brew install zsh```
  - Make default shell: ```chsh -s $(which zsh)```
- Install Nerd Font (for powerline symbols)
  - MacOS: ```brew install --cask font-meslo-lg-nerd-font```
  - Then set it as your terminal font
- Install ZEAL
  - Download [zeal.zsh](https://raw.githubusercontent.com/SeanPedersen/zeal/refs/heads/main/zeal.zsh) or clone this repo
  - Source it from .zshrc (recommended): ```source zeal.zsh```
    - or replace .zshrc: ```cp zeal.zsh ~/.zshrc```

## Shortcuts
- TAB to autocomplete existing paths in CWD
- ARROW RIGHT to autocomplete with current grey auto-suggestion (based on CWD + shell history)

## Structure
- Contextual (cwd + command) history is stored in ~/.zsh_history_contextual

## References

- [ZSH Theme Benchmark](https://github.com/romkatv/zsh-bench/?tab=readme-ov-file#prompt)
- <https://github.com/romkatv/powerlevel10k>
