# ZEAL: smart & fast ZSH config

## ZEAL Features
- Contextual auto-suggestion based on command history of CWD
- Custom CTRL + R: show command history of CWD + dual search (contextual + global history)
- Agnoster inspired theme (showing current git branch + status + commits)
  - runs git fetch (async) on first cd into a git repo (to show new commits from remote)
- Shortens long paths (to first char)
- Print execution timestamp + runtime in secs of last command


https://github.com/user-attachments/assets/a89d975d-e0e7-4bf8-b050-e73b2621d48f


## Install ZEAL
- Install ZSH
  - Debian: ```sudo apt install zsh``` Arch: ```pacman -S zsh```
  - MacOS: ```brew install zsh```
  - Make default shell: ```chsh -s $(which zsh)```
- Install ZEAL
  - Download [zeal.zsh](https://raw.githubusercontent.com/SeanPedersen/zeal/refs/heads/main/zeal.zsh) or clone this repo
  - Source it from .zshrc (recommended): ```source zeal.zsh```
    - or replace .zshrc: ```cp zeal.zsh ~/.zshrc```

## Shortcuts
- TAB to autocomplete existing paths in CWD
- ARROW UP to autocomplete with current grey auto-suggestion (based on CWD + shell history)

## Structure
- Contextual (cwd + command) history is stored in ~/.zsh_history_contextual
