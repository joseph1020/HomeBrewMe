#!/usr/bin/env zsh
# Enable strict error handling and set pipefail
set -euo pipefail
setopt pipefail

# Global variables
global_decision=""
not_found_apps=()
conflict_apps=()
replaced_count=0

# Parse command-line arguments
DRY_RUN=false
ORDER_MODE=false
for arg in "$@"; do
  case $arg in
    --dry-run)
      DRY_RUN=true
      ;;
    --order)
      ORDER_MODE=true
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# Check required commands
for cmd in brew jq python3 osascript; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Please install $cmd and retry."
    exit 1
  fi
done

# Function: Extract the application name from its .app path.
get_app_name() {
  basename "$1" .app
}

# Function: Derive a canonical Homebrew cask name from the application name.
get_cask_name() {
  local app_name="$1"
  local canonical
  canonical=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')
  if brew search --cask "^${canonical}$" &>/dev/null; then
    echo "$canonical"
    return
  fi
  if [[ "$app_name" =~ [[:space:]]+[Cc]lassic$ ]]; then
    local base
    base=$(echo "$app_name" | sed -E 's/[[:space:]]+[Cc]lassic$//')
    local classic_cask
    classic_cask=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')@classic
    if brew search --cask "^${classic_cask}$" &>/dev/null; then
      echo "$classic_cask"
      return
    fi
  fi
  echo "$canonical"
}

# Function: Attempt to quit the application using AppleScript.
quit_app() {
  local app_name="$1"
  echo "Attempting to quit ${app_name}..."
  osascript -e "tell application \"${app_name}\" to quit" 2>/dev/null || true
  # Wait a bit to allow the app to quit gracefully.
  sleep 2
}

# Function: Remove an app directory.
remove_app() {
  local app_path="$1"
  if [ "$DRY_RUN" = false ]; then
    echo "Attempting to remove ${app_path} file-by-file..."
    local failed=0
    while IFS= read -r -d '' file; do
      if ! rm -rf "$file" 2>/dev/null; then
        echo "Failed to remove '$file'. Switching to sudo removal for the entire directory."
        failed=1
        break
      fi
    done < <(find "$app_path" -depth -print0)
    if [ $failed -eq 1 ]; then
      sudo rm -rf "$app_path" || echo "Sudo removal failed for ${app_path}."
    else
      echo "Successfully removed ${app_path}."
    fi
  else
    echo "Dry run: Would remove ${app_path}."
  fi
}

# Function: Interactive reordering of the apps list.
reorder_apps() {
  echo "Found the following applications to process:"
  local i=1
  for app in "${apps[@]}"; do
    echo "$i) $(get_app_name "$app")"
    ((i++))
  done
  echo "Enter numbers (separated by commas or spaces) for the apps to process first (in desired order), or press Enter to keep original order:"
  read user_input
  if [[ -n "$user_input" ]]; then
    local replaced="${user_input//,/ }"
    local chosen_indices
    chosen_indices=("${(@s: :)replaced}")
    local new_apps=()
    if (( ${#chosen_indices[@]} == 1 )); then
      local idx=${chosen_indices[1]}
      if [[ "$idx" =~ '^[0-9]+$' && $idx -ge 1 && $idx -le ${#apps[@]} ]]; then
        local offset=$((idx - 1))
        new_apps=("${apps[@]:$offset}" "${apps[@]:0:$offset}")
      else
        echo "Invalid index: $idx"
        return
      fi
    else
      typeset -A chosen_map
      for idx in "${chosen_indices[@]}"; do
        if [[ "$idx" =~ '^[0-9]+$' && $idx -ge 1 && $idx -le ${#apps[@]} ]]; then
          new_apps+="${apps[$idx]}"
          chosen_map[$idx]=1
        else
          echo "Invalid index: $idx"
        fi
      done
      for (( i=1; i<=${#apps[@]}; i++ )); do
        if [[ -z "${chosen_map[$i]:-}" ]]; then
          new_apps+="${apps[$i]}"
        fi
      done
    fi
    apps=("${new_apps[@]}")
    echo "New processing order:"
    local j=1
    for app in "${apps[@]}"; do
      echo "$j) $(get_app_name "$app")"
      ((j++))
    done
  fi
}

# Function: Process an individual app.
process_app() {
  local app_path="$1"
  local app_name
  app_name=$(get_app_name "$app_path")
  echo "Processing: ${app_name}..."
  
  local cask_name
  cask_name=$(get_cask_name "$app_name")
  
  if ! brew info --cask --json=v2 "$cask_name" &>/dev/null; then
    echo "${app_name} (canonical: ${cask_name}) is not in Homebrew's cask repository. Skipping..."
    not_found_apps+=("$app_name")
    return
  fi
  
  echo "${app_name} is available in Homebrew as ${cask_name} but is not managed by it."
  
  local installed_version
  installed_version=$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  
  # Extract Homebrew version using python3 (with strict=False)
  local brew_version
  brew_version=$(brew info --cask --json=v2 "$cask_name" | python3 -c 'import sys, json; data = json.loads(sys.stdin.read(), strict=False); print(data["casks"][0].get("bundle_short_version") or data["casks"][0].get("version", "unknown"))' 2>/dev/null)
  if [ -z "$brew_version" ] || [ "$brew_version" = "null" ]; then
    brew_version="unknown"
  fi
  
  echo "Installed version: $installed_version"
  echo "Homebrew version: $brew_version"
  
  echo ""
  echo "Brew info for ${cask_name}:"
  brew info --cask "$cask_name"
  echo "---------------------"
  echo ""
  
  local user_choice
  if [ -n "$global_decision" ]; then
    user_choice="$global_decision"
  else
    if [[ "$installed_version" == "$brew_version" ]]; then
      read "user_choice?Installed version matches Homebrew version. Reinstall via Homebrew? [y/N/A(all yes)/F(all no)]: "
    else
      read "user_choice?Version mismatch detected. Replace with Homebrew version? [y/N/A(all yes)/F(all no)]: "
    fi
    if [[ "$user_choice" =~ ^[Aa]$ ]]; then
      global_decision="y"
      user_choice="y"
    elif [[ "$user_choice" =~ ^[Ff]$ ]]; then
      global_decision="n"
      user_choice="n"
    fi
  fi
  
  if [[ "$user_choice" =~ ^[Yy]$ ]]; then
    # Attempt to quit the app before removal.
    quit_app "$app_name"
    if [ -d "$app_path" ]; then
      echo "Removing the manually installed version at ${app_path}..."
      remove_app "$app_path"
    fi
    if [ "$DRY_RUN" = false ]; then
      set +e
      brew install --cask "$cask_name"
      local install_status=$?
      set -e
      if [ $install_status -ne 0 ]; then
        echo "Error: Cask '$cask_name' encountered an installation conflict or error. Skipping installation for ${app_name}."
        conflict_apps+=("$app_name")
      else
        replaced_count=$((replaced_count+1))
      fi
    else
      echo "Dry run: Would install ${cask_name} via Homebrew."
    fi
  else
    echo "Skipping replacement for ${app_name}."
  fi
}

# MAIN EXECUTION

# Get list of .app directories in /Applications (non-recursive)
apps=("${(@f)$(find /Applications -maxdepth 1 -type d -name '*.app')}")
total_apps=${#apps[@]}
echo "Found $total_apps applications in /Applications."

# Get installed Homebrew casks.
installed_brew_casks=($(brew list --cask -1 -l))

# Filter out apps already managed by Homebrew.
filtered_apps=()
for app in "${apps[@]}"; do
  app_name=$(get_app_name "$app")
  cask_name=$(get_cask_name "$app_name")
  if [[ " ${installed_brew_casks[@]} " =~ " ${cask_name} " ]]; then
    echo "Skipping ${app_name}: already managed by Homebrew as ${cask_name}."
  else
    filtered_apps+=("$app")
  fi
done

apps=("${filtered_apps[@]}")
total_apps=${#apps[@]}
echo "Proceeding with $total_apps apps not managed by Homebrew."

if [ "$ORDER_MODE" = true ]; then
  reorder_apps
fi

for (( i=1; i<=total_apps; i++ )); do
  app_path="${apps[$i]}"
  echo "Processing (${i}/${total_apps}): $(get_app_name "$app_path")..."
  process_app "$app_path"
  remaining=$((total_apps - i))
  echo "Apps left: $remaining"
done

echo "Process completed. $replaced_count app(s) have been replaced by Homebrew management."

if (( ${#not_found_apps[@]} > 0 )); then
  echo ""
  echo "The following apps were not found in Homebrew's cask repository. Please review them manually:"
  for app in "${not_found_apps[@]}"; do
    echo " - $app"
  done
fi

if (( ${#conflict_apps[@]} > 0 )); then
  echo ""
  echo "The following apps encountered installation conflicts and were not replaced. Please review them manually:"
  for app in "${conflict_apps[@]}"; do
    echo " - $app"
  done
fi
