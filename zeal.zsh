# ZEAL: smart & fast ZSH config

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE    # Ignore commands that start with a space.
setopt HIST_REDUCE_BLANKS   # Remove unnecessary blank lines.
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY

# Job control settings
setopt NO_NOTIFY            # Don't report background job status immediately
setopt NO_HUP               # Don't kill background jobs on shell exit

# Load hook utilities - deferred to reduce startup cost
_init_hooks() {
  autoload -U add-zle-hook-widget
  autoload -U add-zsh-hook

  # Load substring search widgets
  autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
  zle -N up-line-or-beginning-search
  zle -N down-line-or-beginning-search

  # Register all ZLE hooks
  add-zle-hook-widget line-pre-redraw _autosuggest_modify
  add-zle-hook-widget line-finish _autosuggest_clear_on_finish
  add-zle-hook-widget line-pre-redraw _history_cycle_check_reset
  add-zle-hook-widget line-pre-redraw _menu_search_buffer_change

  # Register directory change hooks
  add-zsh-hook chpwd _auto_git_fetch
  add-zsh-hook chpwd _history_cycle_reset
}

# Schedule hook initialization after prompt
sched +0 _init_hooks

# ----------------------------------------------------------------------------
# Contextual Command History (Directory-Aware Suggestions)
# ----------------------------------------------------------------------------

# Global state for contextual history
typeset -gA _CONTEXTUAL_HISTORY              # dir -> "cmd1\ncmd2\ncmd3" (newest first)
typeset -g _CONTEXTUAL_HISTORY_FILE="$HOME/.zsh_history_contextual"
typeset -g _CONTEXTUAL_HISTORY_LOADED=false
typeset -g _CONTEXTUAL_HISTORY_LOADING=false

# Commands that should always use global history (not contextual)
typeset -ga _CONTEXTUAL_HISTORY_GLOBAL_WHITELIST
_CONTEXTUAL_HISTORY_GLOBAL_WHITELIST=(
  clear history exit source
  ps top htop free df
)

# Track current session commands for ARROW UP/DOWN when buffer is empty
typeset -ga _SESSION_HISTORY_COMMANDS
typeset -g _SESSION_HISTORY_MAX=1000

# State for arrow-up cycling through session -> contextual -> global history
typeset -g _HISTORY_CYCLE_STATE=""           # "session", "contextual", or "global"
typeset -g _HISTORY_CYCLE_INDEX=0            # Current position in list
typeset -g _HISTORY_CYCLE_BUFFER=""          # What user originally typed
typeset -ga _HISTORY_CYCLE_SESSION           # Cached session matches
typeset -ga _HISTORY_CYCLE_CONTEXTUAL        # Cached contextual matches
typeset -g _HISTORY_CYCLE_IN_PROGRESS=false  # Are we mid-cycle?
typeset -g _HISTORY_CYCLE_PWD=""             # Directory where cycling started

# CTRL+R visual menu search state
typeset -g _MENU_SEARCH_ACTIVE=false          # Are we in menu search mode?
typeset -g _MENU_SEARCH_QUERY=""              # Current search query
typeset -ga _MENU_MATCHES_CONTEXTUAL          # Array of contextual matches
typeset -ga _MENU_MATCHES_GLOBAL              # Array of global matches
typeset -g _MENU_SELECTED_INDEX=1             # Currently selected item (1-based)
typeset -g _MENU_DISPLAY_OFFSET=0             # Scroll offset for long lists
typeset -g _MENU_ORIGINAL_BUFFER=""           # Buffer before search started
typeset -g _MENU_ORIGINAL_KEYMAP=""           # Keymap before search started
typeset -g _MENU_MAX_DISPLAY=12               # Max items to display at once

# Signal handler for async load completion (using USR2, USR1 is used by git fetch)
TRAPUSR2() {
  local cache_file="/tmp/zsh_ctx_hist_$$"

  # Source the cached data file
  if [[ -f "$cache_file" ]]; then
    source "$cache_file" 2>/dev/null
    command rm -f "$cache_file" # Prevent alias interference

    _CONTEXTUAL_HISTORY_LOADED=true
    _CONTEXTUAL_HISTORY_LOADING=false

    # Refresh prompt to show it's ready
    zle && zle reset-prompt 2>/dev/null
  fi
}

# Async load contextual history using background process + signal
_load_contextual_history_async() {
  # Don't reload if already loaded or loading
  [[ "$_CONTEXTUAL_HISTORY_LOADED" == "true" ]] && return
  [[ "$_CONTEXTUAL_HISTORY_LOADING" == "true" ]] && return

  # Create file if doesn't exist
  [[ ! -f "$_CONTEXTUAL_HISTORY_FILE" ]] && touch "$_CONTEXTUAL_HISTORY_FILE"

  _CONTEXTUAL_HISTORY_LOADING=true
  local parent_pid=$$

  # Background job to parse and generate cache file
  {
    typeset -A temp_history
    local line dir cmd

    # Read last 10000 lines (most recent commands)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      # Split on first occurrence of |||
      dir="${line%%|||*}"
      cmd="${line#*|||}"

      [[ -z "$cmd" || -z "$dir" || "$cmd" == "$line" ]] && continue

      # Prepend to list for this directory (newest first)
      if [[ -n "${temp_history[$dir]}" ]]; then
        temp_history[$dir]="${cmd}"$'\n'"${temp_history[$dir]}"
      else
        temp_history[$dir]="${cmd}"
      fi
    done < <(tail -10000 "$_CONTEXTUAL_HISTORY_FILE" 2>/dev/null)

    # Write to cache file that parent will source
    local cache_file="/tmp/zsh_ctx_hist_${parent_pid}"
    {
      # Generate shell code to populate the array
      for dir in "${(@k)temp_history}"; do
        # Properly escape the values
        printf '_CONTEXTUAL_HISTORY[%q]=%q\n' "$dir" "${temp_history[$dir]}"
      done
    } > "$cache_file"

    # Signal parent that data is ready (using USR2, not USR1 which is used by git fetch)
    kill -USR2 $parent_pid 2>/dev/null
  } &!
}

# Hook to capture commands with directory context
zshaddhistory() {
  local command="${1%%$'\n'}"
  local reject_command=false

  # Skip if empty or starts with space (HIST_IGNORE_SPACE)
  [[ -z "$command" || "$command" == " "* ]] && return 0

  # Track command in session history (for ARROW UP when buffer is empty)
  _SESSION_HISTORY_COMMANDS+=("$command")
  # Keep only last N commands to prevent memory bloat
  if (( ${#_SESSION_HISTORY_COMMANDS[@]} > _SESSION_HISTORY_MAX )); then
    _SESSION_HISTORY_COMMANDS=(${_SESSION_HISTORY_COMMANDS[@]:(-$_SESSION_HISTORY_MAX)})
  fi

  # Check if command should be stored in contextual history
  local first_word="${command%% *}"
  local store_contextual=true

  # Skip explicit whitelist commands
  if (( ${_CONTEXTUAL_HISTORY_GLOBAL_WHITELIST[(I)$first_word]} )); then
    store_contextual=false
  fi

  # Skip commands with total length < 4 chars (cd, ls, rm, cp, mv, pwd, etc.)
  if (( ${#command} < 4 )); then
    store_contextual=false
  fi

  # Validate that the command exists (skip invalid commands)
  if [[ "$store_contextual" == "true" ]]; then
    # Check if first word is a valid command, function, alias, builtin, or keyword
    # This prevents "command not found" entries from being stored
    if ! (whence -w "$first_word" &>/dev/null); then
      store_contextual=false
      reject_command=true
    fi

    # Special validation for cd command - check if target directory exists
    if [[ "$first_word" == "cd" ]]; then
      # Extract everything after 'cd' (use word splitting)
      local -a cmd_parts
      cmd_parts=(${=command})
      local cd_target="${cmd_parts[2]}"

      # Handle special cases
      if [[ -z "$cd_target" || "$cd_target" == "-" || "$cd_target" == "~" ]]; then
        # cd with no args (goes to $HOME), cd -, or cd ~ are always valid
        :
      elif [[ "$cd_target" == "~/"* ]]; then
        # Expand ~ for validation
        local expanded="${HOME}/${cd_target#~/}"
        if [[ ! -d "$expanded" ]]; then
          store_contextual=false
          reject_command=true
        fi
      else
        # Check if directory exists (relative or absolute path)
        if [[ ! -d "$cd_target" ]]; then
          store_contextual=false
          reject_command=true
        fi
      fi
    fi
  fi

  # Only store in contextual history if not whitelisted and valid
  if [[ "$store_contextual" == "true" ]]; then
    # Append to contextual history file (async writes are fine)
    echo "$PWD|||$command" >> "$_CONTEXTUAL_HISTORY_FILE"

    # Update in-memory index immediately (if loaded)
    if [[ "$_CONTEXTUAL_HISTORY_LOADED" == "true" ]]; then
      # Prepend to directory's command list (newest first)
      if [[ -n "${_CONTEXTUAL_HISTORY[$PWD]}" ]]; then
        _CONTEXTUAL_HISTORY[$PWD]="${command}"$'\n'"${_CONTEXTUAL_HISTORY[$PWD]}"
      else
        _CONTEXTUAL_HISTORY[$PWD]="${command}"
      fi

      # Limit in-memory entries per directory to 100 (prevent memory bloat)
      local cmd_count=$(echo "${_CONTEXTUAL_HISTORY[$PWD]}" | wc -l)
      if (( cmd_count > 100 )); then
        _CONTEXTUAL_HISTORY[$PWD]=$(echo "${_CONTEXTUAL_HISTORY[$PWD]}" | head -100)
      fi
    fi

    # Periodic cleanup of file (every ~1000 commands)
    if (( RANDOM % 1000 == 0 )); then
      ( tail -10000 "$_CONTEXTUAL_HISTORY_FILE" > "${_CONTEXTUAL_HISTORY_FILE}.tmp" 2>/dev/null && \
        mv "${_CONTEXTUAL_HISTORY_FILE}.tmp" "$_CONTEXTUAL_HISTORY_FILE" 2>/dev/null ) &!
    fi
  fi

  # Return 1 to reject from global history if command failed validation
  [[ "$reject_command" == "true" ]] && return 1 || return 0
}

# Fast contextual search for auto-suggestions
_search_contextual_history() {
  local buffer="$1"

  # If not loaded yet, return nothing (will fall back to global)
  [[ "$_CONTEXTUAL_HISTORY_LOADED" != "true" ]] && return 1

  # Check if command is in global whitelist
  local first_word="${buffer%% *}"
  if (( ${_CONTEXTUAL_HISTORY_GLOBAL_WHITELIST[(I)$first_word]} )); then
    # Command is whitelisted - skip contextual lookup
    return 1
  fi

  # Get command list for current directory
  local cmd_list="${_CONTEXTUAL_HISTORY[$PWD]}"
  [[ -z "$cmd_list" ]] && return 1

  # Search through commands (newest first) for prefix match
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Check if this command starts with the buffer
    if [[ "$line" == "$buffer"* && "$line" != "$buffer" ]]; then
      echo "$line"
      return 0
    fi
  done <<< "$cmd_list"

  # No match found
  return 1
}

# Get all contextual matches for cycling (used by arrow-up)
_get_all_contextual_matches() {
  local buffer="$1"
  local -a matches

  # If not loaded yet, return empty
  [[ "$_CONTEXTUAL_HISTORY_LOADED" != "true" ]] && return 1

  # Check if command is in global whitelist
  if [[ -n "$buffer" ]]; then
    local first_word="${buffer%% *}"
    if (( ${_CONTEXTUAL_HISTORY_GLOBAL_WHITELIST[(I)$first_word]} )); then
      # Command is whitelisted - skip contextual lookup
      return 1
    fi
  fi

  # Get command list for current directory
  local cmd_list="${_CONTEXTUAL_HISTORY[$PWD]}"
  [[ -z "$cmd_list" ]] && return 1

  # Collect all matching commands
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # If buffer is empty, match all commands
    # If buffer has text, match only prefix
    if [[ -z "$buffer" || "$line" == "$buffer"* ]]; then
      matches+=("$line")
    fi
  done <<< "$cmd_list"

  # Return matches (one per line)
  if (( ${#matches[@]} > 0 )); then
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  return 1
}

# Get contextual matches using substring search (for CTRL+R menu)
_menu_get_contextual_substring_matches() {
  local query="$1"
  local -a matches
  local -A seen

  # If not loaded yet, return empty
  [[ "$_CONTEXTUAL_HISTORY_LOADED" != "true" ]] && return 1

  # Get command list for current directory
  local cmd_list="${_CONTEXTUAL_HISTORY[$PWD]}"
  [[ -z "$cmd_list" ]] && return 1

  # Collect all matching commands (substring match, deduplicated)
  # Note: cmd_list is already stored newest-first, so we preserve that order
  local line
  local count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Skip if we've already seen this exact command (deduplication)
    [[ -n "${seen[$line]}" ]] && continue

    # If query is empty, match all commands (up to max limit for performance)
    # If query has text, match if line contains query as substring
    if [[ -z "$query" || "$line" == *"$query"* ]]; then
      matches+=("$line")
      seen[$line]=1
      count=$((count + 1))
      # Limit to 100 matches for performance
      [[ $count -ge 100 ]] && break
    fi
  done <<< "$cmd_list"

  # Return matches (one per line) - already newest first, deduplicated
  if (( ${#matches[@]} > 0 )); then
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  return 1
}

# Get global matches using substring search (for CTRL+R menu)
_menu_get_global_substring_matches() {
  local query="$1"
  local max_results=100
  local -a matches
  local -A seen
  local count=0

  # Read from zsh history file directly (more reliable than fc in ZLE context)
  local history_file="${HISTFILE:-$HOME/.zsh_history}"
  [[ ! -f "$history_file" ]] && return 1

  # Read history file in reverse (newest first), extract command part
  local line cmd
  while IFS= read -r line; do
    # ZSH history format: ": timestamp:elapsed;command"
    # Extract just the command part after the semicolon
    if [[ "$line" == ":"*";"* ]]; then
      cmd="${line#*;}"
    else
      # Simple format without timestamp
      cmd="$line"
    fi

    [[ -z "$cmd" ]] && continue

    # Skip if already seen (deduplication)
    [[ -n "${seen[$cmd]}" ]] && continue

    # If query is empty, match all; otherwise check substring
    if [[ -z "$query" || "$cmd" == *"$query"* ]]; then
      matches+=("$cmd")
      seen[$cmd]=1
      count=$((count + 1))
      # Limit results for performance
      [[ $count -ge $max_results ]] && break
    fi
  done < <(tail -2000 "$history_file" 2>/dev/null | tac)

  # Output matches (one per line)
  if (( ${#matches[@]} > 0 )); then
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  return 1
}

# Enable completion system (lazy-loaded)

# Global state for completion system
typeset -g _COMPLETION_LOADED=false
typeset -g _ZCOMPDUMP="${ZDOTDIR:-$HOME}/.zcompdump"

# Function to load completion system synchronously
_load_compinit_now() {
  [[ "$_COMPLETION_LOADED" == "true" ]] && return

  # Completion options (configure before compinit)
  zstyle ':completion:*' menu select
  # Smart matching: case insensitive, then prefix-or-substring (tries prefix first, falls back to substring)
  zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
  setopt COMPLETE_IN_WORD
  setopt AUTO_MENU

  autoload -Uz compinit

  # Run compinit only once a day for performance
  # -C flag skips security check (much faster), only do full check once per day
  if [[ -f "$_ZCOMPDUMP" && -n "$_ZCOMPDUMP"(#qNmh+24) ]]; then
    # File older than 24 hours - do full compinit with security check
    compinit -d "$_ZCOMPDUMP"
  else
    # File is recent - skip expensive security check
    compinit -C -d "$_ZCOMPDUMP"
  fi

  _COMPLETION_LOADED=true
}

# Defer loading: intercept first Tab press
_completion_on_demand() {
  # If not loaded yet, load synchronously (fast enough for UX - will be pre-warmed)
  if [[ "$_COMPLETION_LOADED" != "true" ]]; then
    _load_compinit_now
  fi

  # Now run the actual completion
  zle expand-or-complete
}

# Create ZLE widget for on-demand completion
zle -N _completion_on_demand

# Override Tab to use our on-demand loader
bindkey '^I' _completion_on_demand  # Tab key

# Start loading immediately after prompt (will likely finish before first Tab press)
sched +0 _load_compinit_now

# ----------------------------------------------------------------------------
# History-based Auto-complete
# ----------------------------------------------------------------------------

# Fish-style autosuggestions (lightweight native implementation)
typeset -g _AUTOSUGGEST_SUGGESTION=""

_autosuggest_modify() {
  emulate -L zsh

  # Clear previous suggestion
  _AUTOSUGGEST_SUGGESTION=""
  region_highlight=("${(@)region_highlight:#*autosuggest*}")
  POSTDISPLAY=""

  # Only suggest if buffer is not empty and cursor is at end of buffer
  if [[ -n "$BUFFER" && $CURSOR -eq ${#BUFFER} ]]; then
    local suggestion=""

    # Try contextual history first (blazingly fast!)
    suggestion=$(_search_contextual_history "$BUFFER")

    # Fall back to global history if no contextual match
    if [[ -z "$suggestion" ]]; then
      suggestion=$(fc -lnm "${BUFFER}*" -1 1 2>/dev/null | head -n1)
      # Remove leading spaces from global history
      suggestion="${suggestion## }"
    fi

    if [[ -n "$suggestion" ]]; then
      # Check if suggestion starts with current buffer and is different
      if [[ "$suggestion" != "$BUFFER" && "$suggestion" == "$BUFFER"* ]]; then
        # Extract the completion part
        _AUTOSUGGEST_SUGGESTION="${suggestion#$BUFFER}"

        # Add grey suggestion to buffer display
        POSTDISPLAY="$_AUTOSUGGEST_SUGGESTION"

        # Highlight it in grey
        region_highlight+=("$CURSOR $(( CURSOR + ${#_AUTOSUGGEST_SUGGESTION} )) fg=240,bold autosuggest")
      fi
    fi
  fi
}

_autosuggest_accept() {
  if [[ -n "$_AUTOSUGGEST_SUGGESTION" ]]; then
    BUFFER="$BUFFER$_AUTOSUGGEST_SUGGESTION"
    CURSOR=${#BUFFER}
    _AUTOSUGGEST_SUGGESTION=""
    POSTDISPLAY=""
    region_highlight=()
    zle -R
  fi
}

_autosuggest_clear() {
  _AUTOSUGGEST_SUGGESTION=""
  POSTDISPLAY=""
  region_highlight=()
}

# Create ZLE widgets
zle -N autosuggest-accept _autosuggest_accept
zle -N autosuggest-clear _autosuggest_clear

# Reset history cycling state
_history_cycle_reset() {
  _HISTORY_CYCLE_STATE=""
  _HISTORY_CYCLE_INDEX=0
  _HISTORY_CYCLE_BUFFER=""
  _HISTORY_CYCLE_SESSION=()
  _HISTORY_CYCLE_CONTEXTUAL=()
  _HISTORY_CYCLE_IN_PROGRESS=false
  _HISTORY_CYCLE_PWD=""
}

# ============================================================================
# CTRL+R Menu Search Functions
# ============================================================================

# Reset menu search state
_menu_search_reset() {
  _MENU_SEARCH_ACTIVE=false
  _MENU_SEARCH_QUERY=""
  _MENU_MATCHES_CONTEXTUAL=()
  _MENU_MATCHES_GLOBAL=()
  _MENU_SELECTED_INDEX=1
  _MENU_DISPLAY_OFFSET=0
  _MENU_ORIGINAL_BUFFER=""

  # Clear the menu display
  zle -M ""
}

# Update matches based on current search query
_menu_update_matches() {
  local query="$1"

  # Reset matches
  _MENU_MATCHES_CONTEXTUAL=()
  _MENU_MATCHES_GLOBAL=()

  # Get contextual matches first (prioritize directory-specific history)
  local matches_output
  matches_output=$(_menu_get_contextual_substring_matches "$query")
  if [[ -n "$matches_output" ]]; then
    local line
    while IFS= read -r line; do
      _MENU_MATCHES_CONTEXTUAL+=("$line")
    done <<< "$matches_output"
  fi

  # If no contextual matches, fall back to global history
  if (( ${#_MENU_MATCHES_CONTEXTUAL[@]} == 0 )); then
    local global_matches_output
    global_matches_output=$(_menu_get_global_substring_matches "$query")
    if [[ -n "$global_matches_output" ]]; then
      local line
      while IFS= read -r line; do
        _MENU_MATCHES_GLOBAL+=("$line")
      done <<< "$global_matches_output"
    fi
  fi
}

# Truncate command to fit terminal width
_menu_truncate_command() {
  local cmd="$1"
  local max_len="${2:-80}"

  if (( ${#cmd} > max_len )); then
    echo "${cmd:0:$((max_len - 3))}..."
  else
    echo "$cmd"
  fi
}

# Render the visual menu
_menu_render() {
  local total_contextual=${#_MENU_MATCHES_CONTEXTUAL[@]}
  local total_global=${#_MENU_MATCHES_GLOBAL[@]}

  # If no matches at all, show "no matches" message
  if (( total_contextual == 0 && total_global == 0 )); then
    zle -M "No history matches found"
    return
  fi

  # Get terminal width for proper truncation
  local term_width=${COLUMNS:-80}
  local cmd_width=$((term_width - 10))  # Leave space for prefix and padding

  # Build menu as array of lines (plain text, no colors)
  local -a menu_lines
  local visible_start=$_MENU_DISPLAY_OFFSET
  local visible_end=$((visible_start + _MENU_MAX_DISPLAY))
  local current_idx=0

  # Determine which matches to show
  local -a matches_to_show
  local match_type=""
  if (( total_contextual > 0 )); then
    matches_to_show=("${_MENU_MATCHES_CONTEXTUAL[@]}")
    match_type="contextual"
  else
    matches_to_show=("${_MENU_MATCHES_GLOBAL[@]}")
    match_type="global"
  fi

  # Display matches
  for cmd in "${matches_to_show[@]}"; do
    current_idx=$((current_idx + 1))

    # Skip if before visible window
    (( current_idx < visible_start )) && continue

    # Stop if past visible window
    (( current_idx > visible_end )) && break

    # Highlight selected item
    local truncated_cmd=$(_menu_truncate_command "$cmd" "$cmd_width")
    if (( current_idx == _MENU_SELECTED_INDEX )); then
      menu_lines+=("> ${truncated_cmd}")
    else
      menu_lines+=("  ${truncated_cmd}")
    fi
  done

  # Add match counter at bottom with type indicator
  if [[ "$match_type" == "contextual" ]]; then
    menu_lines+=("[${total_contextual} contextual matches]")
  else
    menu_lines+=("[${total_global} global matches]")
  fi

  # Join lines with newlines and display
  local menu_text="${(F)menu_lines}"
  zle -M "$menu_text"
}

# Update display (refresh prompt and menu)
_menu_update_display() {
  # Render the menu
  _menu_render

  # Keep cursor at end of buffer
  CURSOR=${#BUFFER}
}

# Move selection up or down
_menu_move_selection() {
  local direction="$1"  # -1 for up, +1 for down

  # Determine total matches (contextual or global)
  local total_matches
  if (( ${#_MENU_MATCHES_CONTEXTUAL[@]} > 0 )); then
    total_matches=${#_MENU_MATCHES_CONTEXTUAL[@]}
  else
    total_matches=${#_MENU_MATCHES_GLOBAL[@]}
  fi

  # If no matches, do nothing
  (( total_matches == 0 )) && return

  # Update selected index
  _MENU_SELECTED_INDEX=$((_MENU_SELECTED_INDEX + direction))

  # Wrap around
  if (( _MENU_SELECTED_INDEX < 1 )); then
    _MENU_SELECTED_INDEX=$total_matches
  elif (( _MENU_SELECTED_INDEX > total_matches )); then
    _MENU_SELECTED_INDEX=1
  fi

  # Update scroll offset if needed
  if (( _MENU_SELECTED_INDEX < _MENU_DISPLAY_OFFSET )); then
    _MENU_DISPLAY_OFFSET=$((_MENU_SELECTED_INDEX - 1))
  elif (( _MENU_SELECTED_INDEX > _MENU_DISPLAY_OFFSET + _MENU_MAX_DISPLAY )); then
    _MENU_DISPLAY_OFFSET=$((_MENU_SELECTED_INDEX - _MENU_MAX_DISPLAY))
  fi

  # Update display
  _menu_update_display
}

# ============================================================================
# CTRL+R Menu Widget Functions
# ============================================================================

# Main entry point: Start menu search (CTRL+R)
_menu_search_start() {
  # If already in menu mode, move selection down (cycle through matches)
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    _menu_move_selection 1
    return
  fi

  # Enter menu search mode
  _MENU_SEARCH_ACTIVE=true
  _MENU_ORIGINAL_BUFFER="$BUFFER"
  _MENU_SEARCH_QUERY="$BUFFER"

  # Get initial matches (if buffer is empty, gets last 12 contextual commands)
  _menu_update_matches "$BUFFER"

  # Display menu
  _menu_update_display
}

# Hook to handle buffer changes in menu mode (typing, backspace, etc.)
_menu_search_buffer_change() {
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    # Buffer changed - update query and matches
    if [[ "$BUFFER" != "$_MENU_SEARCH_QUERY" ]]; then
      _MENU_SEARCH_QUERY="$BUFFER"
      _MENU_SELECTED_INDEX=1
      _MENU_DISPLAY_OFFSET=0
      _menu_update_matches "$BUFFER"
      _menu_update_display
    fi
  fi
}

# Handle up arrow in menu mode
_menu_search_up() {
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    _menu_move_selection -1
  else
    # Not in menu mode - use original up arrow behavior
    zle autosuggest-up-or-history
  fi
}

# Handle down arrow in menu mode
_menu_search_down() {
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    _menu_move_selection 1
  else
    # Not in menu mode - use custom down arrow behavior
    zle autosuggest-down-or-history
  fi
}

# Hook that clears suggestions when line is being finalized
_autosuggest_clear_on_finish() {
  _AUTOSUGGEST_SUGGESTION=""
  POSTDISPLAY=""
  region_highlight=()
}

# Handle Enter in menu mode
_menu_search_accept() {
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    # Get the selected command from the appropriate array (contextual or global)
    local selected_cmd=""
    if (( ${#_MENU_MATCHES_CONTEXTUAL[@]} > 0 )); then
      selected_cmd="${_MENU_MATCHES_CONTEXTUAL[$_MENU_SELECTED_INDEX]}"
    else
      selected_cmd="${_MENU_MATCHES_GLOBAL[$_MENU_SELECTED_INDEX]}"
    fi

    # CRITICAL: Set this to false BEFORE modifying BUFFER
    # This prevents the line-pre-redraw hook from interfering
    _MENU_SEARCH_ACTIVE=false

    # Clean up menu state first
    _MENU_SEARCH_QUERY=""
    _MENU_MATCHES_CONTEXTUAL=()
    _MENU_MATCHES_GLOBAL=()
    _MENU_SELECTED_INDEX=1
    _MENU_DISPLAY_OFFSET=0
    _MENU_ORIGINAL_BUFFER=""

    # Clear the menu display
    zle -M ""

    # NOW set buffer to selected command (after everything is cleaned up)
    if [[ -n "$selected_cmd" ]]; then
      BUFFER="$selected_cmd"
      CURSOR=${#BUFFER}
    fi

    # Force a complete redraw to show the selected command
    zle -R

    # Return 0 to indicate success and prevent default Enter behavior
    return 0
  else
    # Not in menu mode - just accept normally, the hook will clear suggestions
    zle .accept-line
  fi
}

# Handle ESC/CTRL+G in menu mode (cancel)
_menu_search_cancel() {
  if [[ "$_MENU_SEARCH_ACTIVE" == "true" ]]; then
    # CRITICAL: Set this to false FIRST, before any operations
    # This prevents the line-pre-redraw hook from re-rendering the menu
    _MENU_SEARCH_ACTIVE=false

    # Clean up ALL state variables immediately
    _MENU_SEARCH_QUERY=""
    _MENU_MATCHES_CONTEXTUAL=()
    _MENU_MATCHES_GLOBAL=()
    _MENU_SELECTED_INDEX=1
    _MENU_DISPLAY_OFFSET=0
    _MENU_ORIGINAL_BUFFER=""

    # Clear ALL ZLE buffers and state
    BUFFER=""
    LBUFFER=""
    RBUFFER=""
    CURSOR=0
    POSTDISPLAY=""

    # Clear autosuggestion state
    _AUTOSUGGEST_SUGGESTION=""
    region_highlight=()

    # Clear the menu display and reset prompt
    zle -M ""
    zle -R

    # Return success to prevent any default key handling
    return 0
  else
    # Not in menu mode - standard CTRL+C behavior
    # Send interrupt to show ^C and start fresh line below
    zle send-break
    return 0
  fi
}

# Handle CTRL+C specifically - use EXACT same behavior as ESC
_menu_search_interrupt() {
  # Just call the cancel function - they should behave identically
  _menu_search_cancel
}

# Hook to reset cycle on buffer modification
_history_cycle_check_reset() {
  if [[ "$_HISTORY_CYCLE_IN_PROGRESS" == "true" ]]; then
    # If buffer changed from what we were cycling, reset
    local current_displayed=""
    if [[ "$_HISTORY_CYCLE_STATE" == "session" && $_HISTORY_CYCLE_INDEX -gt 0 ]]; then
      current_displayed="${_HISTORY_CYCLE_SESSION[$_HISTORY_CYCLE_INDEX]}"
    elif [[ "$_HISTORY_CYCLE_STATE" == "contextual" && $_HISTORY_CYCLE_INDEX -gt 0 ]]; then
      current_displayed="${_HISTORY_CYCLE_CONTEXTUAL[$_HISTORY_CYCLE_INDEX]}"
    fi

    if [[ "$BUFFER" != "$_HISTORY_CYCLE_BUFFER"* && "$BUFFER" != "$current_displayed" ]]; then
      _history_cycle_reset
    fi
  fi
}

# Custom up-arrow: session history first (if empty buffer), then contextual, then global
_autosuggest_up_or_history() {
  # Step 1: Accept suggestion if present
  if [[ -n "$_AUTOSUGGEST_SUGGESTION" ]]; then
    _autosuggest_accept
    return
  fi

  # Step 2: Initialize cycling if not in progress OR directory changed
  if [[ "$_HISTORY_CYCLE_IN_PROGRESS" != "true" ]] || [[ "$_HISTORY_CYCLE_PWD" != "$PWD" ]]; then
    _HISTORY_CYCLE_BUFFER="$BUFFER"
    _HISTORY_CYCLE_INDEX=0
    _HISTORY_CYCLE_IN_PROGRESS=true
    _HISTORY_CYCLE_PWD="$PWD"

    # Determine initial state based on buffer content
    if [[ -z "$BUFFER" ]]; then
      # Empty buffer: start with session history
      _HISTORY_CYCLE_STATE="session"

      # Populate session matches (reverse order - newest first)
      _HISTORY_CYCLE_SESSION=()
      local -i i
      for (( i=${#_SESSION_HISTORY_COMMANDS[@]}; i>0; i-- )); do
        _HISTORY_CYCLE_SESSION+=("${_SESSION_HISTORY_COMMANDS[$i]}")
      done
    else
      # Non-empty buffer: start with contextual history (prefix matching)
      _HISTORY_CYCLE_STATE="contextual"
    fi

    # Get all contextual matches (for when we reach contextual state)
    _HISTORY_CYCLE_CONTEXTUAL=()
    local matches_output
    matches_output=$(_get_all_contextual_matches "$BUFFER")

    if [[ -n "$matches_output" ]]; then
      # Split on newlines - use plain array expansion
      local line
      while IFS= read -r line; do
        _HISTORY_CYCLE_CONTEXTUAL+=("$line")
      done <<< "$matches_output"
    fi
  fi

  # Step 3: Cycle through session history (only when buffer was empty at start)
  if [[ "$_HISTORY_CYCLE_STATE" == "session" ]]; then
    if (( ${#_HISTORY_CYCLE_SESSION[@]} > 0 && _HISTORY_CYCLE_INDEX < ${#_HISTORY_CYCLE_SESSION[@]} )); then
      # Show next session match
      BUFFER="${_HISTORY_CYCLE_SESSION[$((_HISTORY_CYCLE_INDEX + 1))]}"
      CURSOR=${#BUFFER}
      _HISTORY_CYCLE_INDEX=$((_HISTORY_CYCLE_INDEX + 1))
      return
    else
      # Exhausted session matches, switch to contextual
      _HISTORY_CYCLE_STATE="contextual"
      _HISTORY_CYCLE_INDEX=0
    fi
  fi

  # Step 4: Cycle through contextual history
  if [[ "$_HISTORY_CYCLE_STATE" == "contextual" ]]; then
    if (( ${#_HISTORY_CYCLE_CONTEXTUAL[@]} > 0 && _HISTORY_CYCLE_INDEX < ${#_HISTORY_CYCLE_CONTEXTUAL[@]} )); then
      # Show next contextual match
      BUFFER="${_HISTORY_CYCLE_CONTEXTUAL[$((_HISTORY_CYCLE_INDEX + 1))]}"
      CURSOR=${#BUFFER}
      _HISTORY_CYCLE_INDEX=$((_HISTORY_CYCLE_INDEX + 1))
      return
    else
      # Exhausted contextual matches, switch to global
      _HISTORY_CYCLE_STATE="global"
      _HISTORY_CYCLE_INDEX=0
    fi
  fi

  # Step 5: Cycle through global history
  if [[ "$_HISTORY_CYCLE_STATE" == "global" ]]; then
    # Use standard zsh history search
    zle up-line-or-beginning-search
  fi
}

zle -N autosuggest-up-or-history _autosuggest_up_or_history

# Custom down-arrow: reverse cycling through history
_autosuggest_down_or_history() {
  # If not cycling, do nothing (or use standard down behavior)
  if [[ "$_HISTORY_CYCLE_IN_PROGRESS" != "true" ]]; then
    # Standard behavior - go forward in history or do nothing
    zle down-line-or-beginning-search
    return
  fi

  # If we're at the start (original buffer), reset cycling
  if (( _HISTORY_CYCLE_INDEX == 0 )); then
    BUFFER="$_HISTORY_CYCLE_BUFFER"
    CURSOR=${#BUFFER}
    _history_cycle_reset
    return
  fi

  # Go backward through current state
  if [[ "$_HISTORY_CYCLE_STATE" == "session" ]]; then
    # Go back in session history
    if (( _HISTORY_CYCLE_INDEX > 0 )); then
      _HISTORY_CYCLE_INDEX=$((_HISTORY_CYCLE_INDEX - 1))
      if (( _HISTORY_CYCLE_INDEX == 0 )); then
        # Back to original buffer
        BUFFER="$_HISTORY_CYCLE_BUFFER"
      else
        BUFFER="${_HISTORY_CYCLE_SESSION[$_HISTORY_CYCLE_INDEX]}"
      fi
      CURSOR=${#BUFFER}
      return
    fi
  elif [[ "$_HISTORY_CYCLE_STATE" == "contextual" ]]; then
    # Go back in contextual history or back to session
    if (( _HISTORY_CYCLE_INDEX > 0 )); then
      _HISTORY_CYCLE_INDEX=$((_HISTORY_CYCLE_INDEX - 1))
      if (( _HISTORY_CYCLE_INDEX == 0 )); then
        # If we have session history and buffer was empty, go back to session
        if [[ -z "$_HISTORY_CYCLE_BUFFER" && ${#_HISTORY_CYCLE_SESSION[@]} -gt 0 ]]; then
          _HISTORY_CYCLE_STATE="session"
          _HISTORY_CYCLE_INDEX=${#_HISTORY_CYCLE_SESSION[@]}
          BUFFER="${_HISTORY_CYCLE_SESSION[$_HISTORY_CYCLE_INDEX]}"
        else
          # Back to original buffer
          BUFFER="$_HISTORY_CYCLE_BUFFER"
        fi
      else
        BUFFER="${_HISTORY_CYCLE_CONTEXTUAL[$_HISTORY_CYCLE_INDEX]}"
      fi
      CURSOR=${#BUFFER}
      return
    fi
  elif [[ "$_HISTORY_CYCLE_STATE" == "global" ]]; then
    # Go back in global history or back to contextual
    # For global, we need to transition back to contextual
    if (( ${#_HISTORY_CYCLE_CONTEXTUAL[@]} > 0 )); then
      _HISTORY_CYCLE_STATE="contextual"
      _HISTORY_CYCLE_INDEX=${#_HISTORY_CYCLE_CONTEXTUAL[@]}
      BUFFER="${_HISTORY_CYCLE_CONTEXTUAL[$_HISTORY_CYCLE_INDEX]}"
      CURSOR=${#BUFFER}
    elif (( ${#_HISTORY_CYCLE_SESSION[@]} > 0 && -z "$_HISTORY_CYCLE_BUFFER" )); then
      # No contextual, but has session (and buffer was empty)
      _HISTORY_CYCLE_STATE="session"
      _HISTORY_CYCLE_INDEX=${#_HISTORY_CYCLE_SESSION[@]}
      BUFFER="${_HISTORY_CYCLE_SESSION[$_HISTORY_CYCLE_INDEX]}"
      CURSOR=${#BUFFER}
    else
      # Back to original buffer
      BUFFER="$_HISTORY_CYCLE_BUFFER"
      CURSOR=${#BUFFER}
      _history_cycle_reset
    fi
    return
  fi
}

zle -N autosuggest-down-or-history _autosuggest_down_or_history

# Register menu search widgets
zle -N menu-search-start _menu_search_start
zle -N menu-search-up _menu_search_up
zle -N menu-search-down _menu_search_down
zle -N menu-search-accept _menu_search_accept
zle -N menu-search-cancel _menu_search_cancel
zle -N menu-search-interrupt _menu_search_interrupt

# Note: We use a line-pre-redraw hook to handle typing in menu mode
# This is simpler than creating a custom keymap

# Key bindings
# CTRL+R: Start contextual history menu search
bindkey '^R' menu-search-start

# Arrow keys (support both standard and application mode)
bindkey '^[[A' menu-search-up                 # Up arrow: menu navigation or history
bindkey '^[OA' menu-search-up                 # Up arrow (application mode)
bindkey '^[[B' menu-search-down               # Down arrow: menu navigation or history
bindkey '^[OB' menu-search-down               # Down arrow (application mode)
bindkey '^[[C' forward-char                   # Right arrow: moves cursor forward
bindkey '^[OC' forward-char                   # Right arrow (application mode)

# Disable terminal interrupt character by default so ZLE can handle CTRL+C
# This will be re-enabled in preexec() before commands run, and disabled again in precmd()
stty intr undef

# Menu search control keys
bindkey '^M' menu-search-accept               # Enter: accept selection or normal accept
bindkey '^C' menu-search-interrupt            # CTRL+C: interrupt/cancel search
bindkey '^G' menu-search-cancel               # CTRL+G: cancel search
bindkey '^[' menu-search-cancel               # ESC: cancel search

bindkey '^F' autosuggest-accept               # Ctrl+F: accepts whole suggestion
bindkey '^ ' autosuggest-accept               # Ctrl+Space: accepts whole suggestion

# Better navigation keybindings
bindkey '^[[1;5C' forward-word                # Ctrl+→: jump word forward
bindkey '^[[1;5D' backward-word               # Ctrl+←: jump word backward
bindkey '^H' backward-kill-word               # Ctrl+Backspace: delete word backward
bindkey '^[[3~' delete-char                   # Delete: delete char forward
bindkey '^[[3;5~' kill-word                   # Ctrl+Delete: delete word forward

# Character selection with SHIFT + arrow keys
_select_char_forward() {
  ((REGION_ACTIVE)) || zle set-mark-command
  zle forward-char
}

_select_char_backward() {
  ((REGION_ACTIVE)) || zle set-mark-command
  zle backward-char
}

# Word selection with CTRL + SHIFT + arrow keys
_select_word_forward() {
  ((REGION_ACTIVE)) || zle set-mark-command
  zle forward-word
}

_select_word_backward() {
  ((REGION_ACTIVE)) || zle set-mark-command
  zle backward-word
}

# Copy selected region to clipboard using OSC 52 (works in modern terminals)
_copy_selection() {
  if ((REGION_ACTIVE)); then
    zle copy-region-as-kill

    # Use OSC 52 escape sequence to copy directly to system clipboard
    # This works in Ghostty, iTerm2, tmux, and many modern terminals
    local copy_data="${CUTBUFFER}"
    local encoded=$(echo -n "$copy_data" | base64 | tr -d '\n')
    printf "\033]52;c;${encoded}\a"

    # Fallback to clipboard utilities if OSC 52 doesn't work
    if command -v xclip &> /dev/null; then
      echo -n "$CUTBUFFER" | xclip -selection clipboard
    elif command -v xsel &> /dev/null; then
      echo -n "$CUTBUFFER" | xsel --clipboard --input
    elif command -v wl-copy &> /dev/null; then
      echo -n "$CUTBUFFER" | wl-copy
    elif command -v pbcopy &> /dev/null; then
      echo -n "$CUTBUFFER" | pbcopy
    fi
  fi
}

# Cut selected region to clipboard using OSC 52
_cut_selection() {
  if ((REGION_ACTIVE)); then
    zle kill-region

    # Use OSC 52 escape sequence to copy directly to system clipboard
    local copy_data="${CUTBUFFER}"
    local encoded=$(echo -n "$copy_data" | base64 | tr -d '\n')
    printf "\033]52;c;${encoded}\a"

    # Fallback to clipboard utilities if OSC 52 doesn't work
    if command -v xclip &> /dev/null; then
      echo -n "$CUTBUFFER" | xclip -selection clipboard
    elif command -v xsel &> /dev/null; then
      echo -n "$CUTBUFFER" | xsel --clipboard --input
    elif command -v wl-copy &> /dev/null; then
      echo -n "$CUTBUFFER" | wl-copy
    elif command -v pbcopy &> /dev/null; then
      echo -n "$CUTBUFFER" | pbcopy
    fi
  fi
}

zle -N select-char-forward _select_char_forward
zle -N select-char-backward _select_char_backward
zle -N select-word-forward _select_word_forward
zle -N select-word-backward _select_word_backward
zle -N copy-selection _copy_selection
zle -N cut-selection _cut_selection

# Try multiple escape sequences for different terminals
bindkey '^[[1;2C' select-char-forward         # SHIFT+→: select char forward
bindkey '^[[1;2D' select-char-backward        # SHIFT+←: select char backward
bindkey '^[OC' select-char-forward            # SHIFT+→ (alternate)
bindkey '^[OD' select-char-backward           # SHIFT+← (alternate)

bindkey '^[[1;6C' select-word-forward         # CTRL+SHIFT+→: select word forward
bindkey '^[[1;6D' select-word-backward        # CTRL+SHIFT+←: select word backward

# Copy/Cut bindings
bindkey '^[[67;6u' copy-selection             # CTRL+SHIFT+C: copy selection (Ghostty)
bindkey '^[[99;5u' copy-selection             # CTRL+SHIFT+C: copy selection (alternate)
bindkey '^[c' copy-selection                  # Alt+C: copy selection (fallback)
bindkey '^[x' cut-selection                   # Alt+X: cut selection

# Debug function: run this to see what keys send
# Usage: zsh-debug-keys, then press your key combo, then Ctrl+C
zsh-debug-keys() {
  echo "Press your key combination (Ctrl+C to exit):"
  cat -v
}

# ----------------------------------------------------------------------------
# Command Execution Time Tracking & iTerm Title
# ----------------------------------------------------------------------------

# Initialize exit code to 0 (for first prompt)
typeset -g cmd_exit_code=0

function set_iterm_title() {
  echo -ne "\033]0;${PWD##*/} - $1\007"
}

preexec() {
  # Reset history cycling when executing a command (start fresh for next ARROW UP)
  _history_cycle_reset

  # Clear any remaining auto-suggestions
  _AUTOSUGGEST_SUGGESTION=""
  POSTDISPLAY=""
  region_highlight=()

  # Start timer for execution time
  cmd_start_time=$SECONDS

  # Set iTerm title to command being executed
  set_iterm_title "$1"

  # Re-enable CTRL+C for interrupting commands
  stty intr '^C'
}

precmd() {
  # MUST capture exit code first, before any other commands run
  local last_exit_code=$?

  # Reset the git check flags for next prompt cycle
  _VCS_INFO_CURRENT_HEAD_CHECKED=false
  _VCS_INFO_REGENERATED_THIS_CYCLE=false

  # Calculate execution time
  if [ -n "$cmd_start_time" ]; then
    # A command was executed - use its exit code
    cmd_exit_code=$last_exit_code

    local cmd_end_time=$SECONDS
    # Convert to integer for arithmetic (handles both int and float SECONDS)
    local elapsed=$(( ${cmd_end_time%.*} - ${cmd_start_time%.*} ))

    # Format execution time
    if (( elapsed >= 60 )); then
      local minutes=$(( elapsed / 60 ))
      local seconds=$(( elapsed % 60 ))
      cmd_exec_time="${minutes}m ${seconds}s"
    else
      cmd_exec_time="${elapsed}s"
    fi

    unset cmd_start_time
  else
    # No command was executed (empty line) - reset exit code
    cmd_exit_code=0
    cmd_exec_time=""
  fi

  # Set iTerm title back to zsh
  set_iterm_title "zsh"

  # Disable CTRL+C interrupt character so ZLE can handle it
  stty intr undef
}

# ----------------------------------------------------------------------------
# Agnoster-style Prompt with Git Branch
# ----------------------------------------------------------------------------

# Colors work with %F{} syntax, no need to load colors module

# Lazy-load vcs_info on first use
typeset -g _VCS_INFO_LOADED=false

# PROMPT_SUBST needed for dynamic prompt evaluation
setopt PROMPT_SUBST

_init_vcs_info() {
  [[ "$_VCS_INFO_LOADED" == "true" ]] && return

  # Load version control info
  autoload -Uz vcs_info

  # Configure vcs_info for git
  zstyle ':vcs_info:*' enable git
  zstyle ':vcs_info:*' check-for-changes true
  zstyle ':vcs_info:*' unstagedstr '●'
  zstyle ':vcs_info:*' stagedstr '✚'
  zstyle ':vcs_info:git:*' formats ' ⎇ %b%F{yellow}%u%c%f%m'
  zstyle ':vcs_info:git:*' actionformats ' ⎇ %b|%a%F{yellow}%u%c%f%m'

  zstyle ':vcs_info:git*+set-message:*' hooks git-aheadbehind

  _VCS_INFO_LOADED=true
}

# Git ahead/behind info (optimized with single git command)
+vi-git-aheadbehind() {
  local ahead behind
  local -a gitstatus

  # Use faster single command to get both ahead and behind counts
  local ab_output=$(git rev-list --left-right --count ${hook_com[branch]}@{upstream}...HEAD 2>/dev/null)

  if [[ -n "$ab_output" ]]; then
    behind=${ab_output%%[[:space:]]*}
    ahead=${ab_output##*[[:space:]]}

    if [[ "$ahead" -gt 0 ]]; then
      gitstatus+=("↑${ahead}")
    fi
    if [[ "$behind" -gt 0 ]]; then
      gitstatus+=("↓${behind}")
    fi

    if [[ ${#gitstatus[@]} -gt 0 ]]; then
      hook_com[misc]=" %F{black}${(j: :)gitstatus}%f"
    fi
  fi
}

# Cache for vcs_info to prevent multiple calls
typeset -g _VCS_INFO_CACHE=""
typeset -g _VCS_INFO_CACHE_PWD=""
typeset -g _VCS_INFO_CACHE_HEAD=""
typeset -g _VCS_INFO_CACHE_STATUS=""
typeset -g _VCS_INFO_CACHE_UPSTREAM=""
typeset -g _VCS_INFO_CURRENT_HEAD_CHECKED=false
typeset -g _VCS_INFO_CURRENT_HEAD=""
typeset -g _VCS_INFO_CURRENT_STATUS=""
typeset -g _VCS_INFO_CURRENT_UPSTREAM=""
typeset -g _VCS_INFO_REGENERATED_THIS_CYCLE=false

# Check git HEAD once per prompt cycle
precmd_check_git_head() {
  # Guard: only run once per prompt cycle
  if [[ "$_VCS_INFO_CURRENT_HEAD_CHECKED" == "true" ]]; then
    return
  fi

  _VCS_INFO_CURRENT_HEAD=""
  _VCS_INFO_CURRENT_UPSTREAM=""

  # Only check once - cache for this prompt cycle
  if git rev-parse --git-dir > /dev/null 2>&1; then
    _VCS_INFO_CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null)
    # Also check if there are uncommitted changes for cache invalidation
    # This is fast: just checks if index/worktree differ from HEAD
    _VCS_INFO_CURRENT_STATUS=$(git status --porcelain 2>/dev/null | head -1)
    # Check upstream HEAD to detect remote changes (push/pull/fetch)
    local current_branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$current_branch" ]]; then
      _VCS_INFO_CURRENT_UPSTREAM=$(git rev-parse "origin/$current_branch" 2>/dev/null)
    fi
  fi
  _VCS_INFO_CURRENT_HEAD_CHECKED=true
}

# Update vcs_info before each prompt (with caching)
precmd_vcs_info() {
  # Initialize vcs_info on first call
  _init_vcs_info

  # Use the HEAD and status that were checked once at the start of this prompt cycle
  local current_head="$_VCS_INFO_CURRENT_HEAD"
  local current_status="$_VCS_INFO_CURRENT_STATUS"
  local current_upstream="$_VCS_INFO_CURRENT_UPSTREAM"

  # Fast path: if PWD, HEAD, status, and upstream haven't changed, use cache
  if [[ "$PWD" == "$_VCS_INFO_CACHE_PWD" && "$current_head" == "$_VCS_INFO_CACHE_HEAD" && "$current_status" == "$_VCS_INFO_CACHE_STATUS" && "$current_upstream" == "$_VCS_INFO_CACHE_UPSTREAM" ]]; then
    vcs_info_msg_0_="$_VCS_INFO_CACHE"
    return
  fi

  # Guard: only regenerate once per cycle even if conditions changed
  if [[ "$_VCS_INFO_REGENERATED_THIS_CYCLE" == "true" ]]; then
    vcs_info_msg_0_="$_VCS_INFO_CACHE"
    return
  fi

  # Regenerate vcs_info
  vcs_info
  _VCS_INFO_CACHE="$vcs_info_msg_0_"
  _VCS_INFO_CACHE_PWD="$PWD"
  _VCS_INFO_CACHE_HEAD="$current_head"
  _VCS_INFO_CACHE_STATUS="$current_status"
  _VCS_INFO_CACHE_UPSTREAM="$current_upstream"
  _VCS_INFO_REGENERATED_THIS_CYCLE=true
}

precmd_functions+=( precmd_check_git_head precmd_vcs_info )

# ----------------------------------------------------------------------------
# Smart Git Fetch on Directory Change
# ----------------------------------------------------------------------------

# Track current git repo
typeset -g _CURRENT_GIT_REPO=""
typeset -g _GIT_FETCH_IN_PROGRESS=false

# Signal handler for async git fetch completion
TRAPUSR1() {
  _GIT_FETCH_IN_PROGRESS=false

  # Clear all vcs_info cache to force complete refresh
  _VCS_INFO_CACHE=""
  _VCS_INFO_CACHE_PWD=""
  _VCS_INFO_CACHE_HEAD=""
  _VCS_INFO_CACHE_STATUS=""
  _VCS_INFO_CACHE_UPSTREAM=""
  _VCS_INFO_CURRENT_HEAD_CHECKED=false
  _VCS_INFO_CURRENT_HEAD=""
  _VCS_INFO_CURRENT_STATUS=""
  _VCS_INFO_CURRENT_UPSTREAM=""
  _VCS_INFO_REGENERATED_THIS_CYCLE=false

  # Force regeneration of vcs_info by calling precmd hooks
  precmd_check_git_head
  precmd_vcs_info

  # Reset prompt to show updated git info immediately
  if zle; then
    zle reset-prompt 2>/dev/null
  fi

  #echo -e "\r\033[0;90m[fetch complete]\033[0m"
}

# Function to run git fetch when entering new repo
_auto_git_fetch() {
  # Quick check: if we're still in the cached repo, skip everything
  if [[ -n "$_CURRENT_GIT_REPO" && "$PWD" == "$_CURRENT_GIT_REPO"* ]]; then
    return
  fi

  # Check if we're in a git repo
  if git rev-parse --git-dir > /dev/null 2>&1; then
    local git_root=$(git rev-parse --show-toplevel 2>/dev/null)

    # Only fetch if this is a different repo than before
    if [[ "$git_root" != "$_CURRENT_GIT_REPO" ]]; then
      _CURRENT_GIT_REPO="$git_root"

      # Skip if a fetch is already in progress
      if [[ "$_GIT_FETCH_IN_PROGRESS" == "true" ]]; then
        return
      fi

      # Fetch only current branch asynchronously
      local current_branch=$(git branch --show-current 2>/dev/null)
      if [[ -n "$current_branch" ]]; then
        _GIT_FETCH_IN_PROGRESS=true
        #echo -e "\033[0;90m[fetching origin/$current_branch...]\033[0m"

        # Run fetch in background and signal parent when done
        local parent_pid=$$
        (
          git fetch origin "$current_branch" 2>/dev/null
          # Signal parent shell that fetch is complete
          kill -USR1 $parent_pid 2>/dev/null
        ) &!
      fi
    fi
  else
    # Not in a git repo anymore
    _CURRENT_GIT_REPO=""
  fi
}

# Defer git fetch to after prompt is displayed (non-blocking startup)
# Schedule to run after current event loop
zmodload zsh/sched
sched +0 _auto_git_fetch

# Powerline separator
POWERLINE_SEPARATOR=$'\uE0B0'  #

# Prompt segments
prompt_status() {
  # Show red X if last command failed
  if [[ $cmd_exit_code -ne 0 ]]; then
    echo "%F{red}✗ %f"
  fi
}

prompt_user() {
  local user="%n"
  local host="%m"
  local default_user="$(stat -c '%U' "$HOME" 2>/dev/null || stat -f '%Su' "$HOME" 2>/dev/null)"

  # Only show username if not default user or in SSH
  if [[ "$USER" != "$default_user" || -n "$SSH_CLIENT" ]]; then
    echo "%F{white}%K{black} ${user}@${host} %k%f"
  fi
}

# Shorten path: keep only first char of each dir except last (fish-style)
_shorten_path() {
  local path="${PWD/#$HOME/~}"
  local -a path_parts
  path_parts=("${(@s:/:)path}")

  # If only one or zero parts, return as-is
  if [[ ${#path_parts[@]} -le 1 ]]; then
    echo "$path"
    return
  fi

  local -a shortened
  # Process all parts except the last
  for i in {1..$(( ${#path_parts[@]} - 1 ))}; do
    if [[ -n "${path_parts[$i]}" ]]; then
      shortened+=("${path_parts[$i]:0:1}")
    else
      # Handle leading slash for absolute paths
      shortened+=("")
    fi
  done
  # Add the last part in full
  shortened+=("${path_parts[-1]}")

  echo "${(j:/:)shortened}"
}

prompt_dir() {
  # Don't add separator here - let git segment handle it
  echo "%K{blue}%F{black} $(_shorten_path) %k%f"
}

prompt_git() {
  if [[ -n ${vcs_info_msg_0_} ]]; then
    # Blue triangle on green background for transition, then git info, then green triangle
    echo "%K{green}%F{blue}${POWERLINE_SEPARATOR}%f%F{black}${vcs_info_msg_0_} %k%f%F{green}${POWERLINE_SEPARATOR}%f"
  else
    # No git branch - just blue triangle
    echo "%F{blue}${POWERLINE_SEPARATOR}%f"
  fi
}

# Build prompt
PROMPT='$(prompt_status)$(prompt_user)$(prompt_dir)$(prompt_git) '

# Right prompt with execution time
RPROMPT='%F{green}${cmd_exec_time:+took $cmd_exec_time} %D{%H:%M:%S}%f'

# ----------------------------------------------------------------------------
# Initialize Contextual History
# ----------------------------------------------------------------------------

# Defer loading contextual history to after prompt is displayed (non-blocking startup)
# This improves perceived startup time significantly
sched +0 _load_contextual_history_async
