#!/usr/bin/env zsh
# Replace manually installed applications with Homebrew cask versions
# Enable strict error handling and set pipefail
set -euo pipefail
setopt pipefail

# Global variables
global_decision=""
typeset -a not_found_apps
typeset -a conflict_apps
replaced_count=0

# Parse command-line arguments
DRY_RUN=false
ORDER_MODE=false
VERBOSE=false

# Help message
show_help() {
  cat << EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run     Show what would be done without making changes
  --order       Interactively reorder applications to process
  --verbose     Show detailed output
  --help        Display this help message

Description:
  This script replaces manually installed Mac applications with their 
  Homebrew cask equivalents, ensuring they are managed by Homebrew.
EOF
  exit 0
}

# Process command-line arguments
for arg in "$@"; do
  case $arg in
    --dry-run)
      DRY_RUN=true
      ;;
    --order)
      ORDER_MODE=true
      ;;
    --verbose)
      VERBOSE=true
      ;;
    --help)
      show_help
      ;;
    -*)
      echo "Unknown option: $arg"
      echo "Use --help for usage information."
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
  local app_path="$1"
  basename "$app_path" .app
}

# Function: Check if a cask exists in brew
check_cask_exists() {
  local cask_name="$1"
  if brew info --cask "$cask_name" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Function: Derive a canonical Homebrew cask name from the application name.
get_cask_name() {
  local app_name="$1"
  local canonical
  
  # Try direct conversion
  canonical=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')
  if check_cask_exists "$canonical"; then
    echo "$canonical"
    return
  fi
  
  # Try with app name only (remove "for Mac" etc.)
  local simplified
  simplified=$(echo "$app_name" | sed -E 's/ (for|on) Mac( OS( X)?)?$//i' | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')
  if [[ "$simplified" != "$canonical" ]] && check_cask_exists "$simplified"; then
    echo "$simplified"
    return
  fi
  
  # Try classic version
  if [[ "$app_name" =~ [[:space:]][Cc]lassic$ ]]; then
    local base
    base=$(echo "$app_name" | sed -E 's/[[:space:]][Cc]lassic$//')
    local classic_cask
    classic_cask=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g')@classic
    if check_cask_exists "$classic_cask"; then
      echo "$classic_cask"
      return
    fi
  fi
  
  # Return the canonical name as fallback
  echo "$canonical"
}

# Function: Attempt to quit the application using AppleScript.
quit_app() {
  local app_name="$1"
  echo "Attempting to quit ${app_name}..."
  osascript -e "tell application \"${app_name}\" to quit" 2>/dev/null || true
  
  # Check if app is still running
  sleep 2
  if pgrep -f "$app_name" &>/dev/null; then
    echo "Warning: $app_name may still be running."
    read -q "?Force continue? [y/N]: " force_continue
    echo ""
    if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
      echo "Aborting operation for $app_name."
      return 1
    fi
  fi
  return 0
}

# Function: Remove an app directory.
remove_app() {
  local app_path="$1"
  if [ "$DRY_RUN" = false ]; then
    echo "Attempting to remove ${app_path} file-by-file..."
    local failed=0
    
    # Check write permissions
    if [ ! -w "$app_path" ]; then
      echo "No write permissions for $app_path. Using sudo removal."
      sudo rm -rf "$app_path" || { echo "Sudo removal failed for ${app_path}."; return 1; }
      return 0
    fi
    
    # Try to remove file by file
    while IFS= read -r -d '' file; do
      if ! rm -rf "$file" 2>/dev/null; then
        echo "Failed to remove '$file'. Switching to sudo removal for the entire directory."
        failed=1
        break
      fi
    done < <(find "$app_path" -depth -print0)
    
    if [ $failed -eq 1 ]; then
      sudo rm -rf "$app_path" || { echo "Sudo removal failed for ${app_path}."; return 1; }
    else
      echo "Successfully removed ${app_path}."
    fi
  else
    echo "Dry run: Would remove ${app_path}."
  fi
}

# Function: Compare version strings
compare_versions() {
  local v1="$1"
  local v2="$2"
  
  if [[ "$v1" == "unknown" || "$v2" == "unknown" ]]; then
    echo "unknown"
    return
  fi
  
  # Convert versions to arrays
  local v1_parts=("${(@s:.:)v1}")
  local v2_parts=("${(@s:.:)v2}")
  
  # Compare version components
  local max_parts=$((${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]}))
  
  for ((i=1; i<=max_parts; i++)); do
    local v1_part=${v1_parts[$i]:-0}
    local v2_part=${v2_parts[$i]:-0}
    
    # Remove non-numeric parts for comparison
    v1_part=${v1_part//[^0-9]/}
    v2_part=${v2_part//[^0-9]/}
    
    # Default to 0 if empty
    v1_part=${v1_part:-0}
    v2_part=${v2_part:-0}
    
    if ((10#$v1_part > 10#$v2_part)); then
      echo "newer"
      return
    elif ((10#$v1_part < 10#$v2_part)); then
      echo "older"
      return
    fi
  done
  
  echo "same"
}

# Function: Interactive reordering of the apps list.
reorder_apps() {
  echo "Found the following applications to process:"
  local i=1
  for app in "${apps[@]}"; do
    echo "$i) $(get_app_name "$app")"
    ((i++))
  done
  
  echo ""
  echo "Enter numbers (separated by commas or spaces) for the apps to process first"
  echo "(in desired order), or press Enter to keep original order:"
  read user_input
  
  if [[ -n "$user_input" ]]; then
    local replaced="${user_input//,/ }"
    local chosen_indices=("${(@s: :)replaced}")
    typeset -a new_apps
    
    # Handle rotation case (one number entered)
    if (( ${#chosen_indices[@]} == 1 )); then
      local idx=${chosen_indices[1]}
      if [[ "$idx" =~ ^[0-9]+$ && $idx -ge 1 && $idx -le ${#apps[@]} ]]; then
        new_apps=("${apps[@]:$idx-1}" "${apps[@]:0:$idx-1}")
      else
        echo "Invalid index: $idx"
        return
      fi
    else
      # Handle reordering case (multiple numbers)
      typeset -A chosen_map
      
      # First add selected apps in order
      for idx in "${chosen_indices[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ && $idx -ge 1 && $idx -le ${#apps[@]} ]]; then
          new_apps+=("${apps[$idx]}")
          chosen_map[$idx]=1
        else
          echo "Invalid index: $idx"
        fi
      done
      
      # Then add remaining apps
      for ((i=1; i<=${#apps[@]}; i++)); do
        if [[ -z "${chosen_map[$i]:-}" ]]; then
          new_apps+=("${apps[$i]}")
        fi
      done
    fi
    
    # Update apps array with new order
    if (( ${#new_apps[@]} > 0 )); then
      apps=("${new_apps[@]}")
      echo "New processing order:"
      local j=1
      for app in "${apps[@]}"; do
        echo "$j) $(get_app_name "$app")"
        ((j++))
      done
    fi
  fi
}

# Function: Process an individual app.
process_app() {
  local app_path="$1"
  
  # Validate app path
  if [ ! -d "$app_path" ]; then
    echo "Error: $app_path no longer exists. Skipping..."
    return
  }
  
  local app_name
  app_name=$(get_app_name "$app_path")
  echo "Processing: ${app_name}..."
  
  local cask_name
  cask_name=$(get_cask_name "$app_name")
  
  if ! check_cask_exists "$cask_name"; then
    echo "${app_name} (canonical: ${cask_name}) is not in Homebrew's cask repository. Skipping..."
    not_found_apps+=("$app_name")
    return
  fi
  
  echo "${app_name} is available in Homebrew as ${cask_name}."
  
  # Get installed version
  local installed_version
  installed_version=$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  
  # Get Homebrew version
  local brew_info
  brew_info=$(brew info --cask --json=v2 "$cask_name" 2>/dev/null)
  
  # Extract version with better error handling
  local brew_version
  brew_version=$(echo "$brew_info" | python3 -c '
import sys, json
try:
    data = json.loads(sys.stdin.read())
    cask = data["casks"][0]
    version = cask.get("version", "unknown")
    bundle_version = cask.get("version_scheme", {}).get("bundle_short_version", "")
    print(bundle_version if bundle_version else version)
except Exception as e:
    print("unknown")
' 2>/dev/null || echo "unknown")
  
  if [ -z "$brew_version" ] || [ "$brew_version" = "null" ]; then
    brew_version="unknown"
  fi
  
  echo "Installed version: $installed_version"
  echo "Homebrew version: $brew_version"
  
  # Compare versions
  local version_comparison
  version_comparison=$(compare_versions "$installed_version" "$brew_version")
  
  # Show full brew info in verbose mode
  if [ "$VERBOSE" = true ]; then
    echo ""
    echo "Brew info for ${cask_name}:"
    brew info --cask "$cask_name"
    echo "---------------------"
    echo ""
  fi
  
  # Ask user for decision
  local user_choice
  if [ -n "$global_decision" ]; then
    user_choice="$global_decision"
  else
    case "$version_comparison" in
      "same")
        read "user_choice?Installed version matches Homebrew version. Reinstall via Homebrew? [y/N/A(all yes)/F(all no)]: "
        ;;
      "newer")
        read "user_choice?Installed version ($installed_version) is NEWER than Homebrew version ($brew_version). Replace anyway? [y/N/A(all yes)/F(all no)]: "
        ;;
      "older")
        read "user_choice?Installed version ($installed_version) is OLDER than Homebrew version ($brew_version). Replace with newer version? [y/N/A(all yes)/F(all no)]: "
        ;;
      *)
        read "user_choice?Version comparison inconclusive. Replace with Homebrew version? [y/N/A(all yes)/F(all no)]: "
        ;;
    esac
    
    if [[ "$user_choice" =~ ^[Aa]$ ]]; then
      global_decision="y"
      user_choice="y"
    elif [[ "$user_choice" =~ ^[Ff]$ ]]; then
      global_decision="n"
      user_choice="n"
    fi
  fi
  
  if [[ "$user_choice" =~ ^[Yy]$ ]]; then
    # Attempt to quit the app before removal
    quit_app "$app_name" || return
    
    if [ -d "$app_path" ]; then
      echo "Removing the manually installed version at ${app_path}..."
      remove_app "$app_path" || return
    fi
    
    if [ "$DRY_RUN" = false ]; then
      echo "Installing ${cask_name} via Homebrew..."
      set +e
      brew install --cask "$cask_name"
      local install_status=$?
      set -e
      
      if [ $install_status -ne 0 ]; then
        echo "Error: Cask '$cask_name' encountered an installation conflict or error."
        conflict_apps+=("$app_name")
      else
        echo "Successfully replaced ${app_name} with Homebrew-managed ${cask_name}."
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

# Display script banner
echo "======================================================"
echo "  macOS App to Homebrew Cask Replacement Tool"
echo "  Mode: $([ "$DRY_RUN" = true ] && echo "DRY RUN (no changes)" || echo "LIVE")"
echo "======================================================"

# Get list of .app directories in /Applications (non-recursive)
echo "Scanning /Applications directory..."
typeset -a apps
apps=("${(@f)$(find /Applications -maxdepth 1 -type d -name '*.app')}")
total_apps=${#apps[@]}
echo "Found $total_apps applications in /Applications."

# Get installed Homebrew casks
echo "Getting installed Homebrew casks..."
typeset -a installed_brew_casks
installed_brew_casks=($(brew list --cask -1))

# Filter out apps already managed by Homebrew
echo "Filtering out apps already managed by Homebrew..."
typeset -a filtered_apps
for app in "${apps[@]}"; do
  if [ ! -d "$app" ]; then
    continue
  fi
  
  app_name=$(get_app_name "$app")
  cask_name=$(get_cask_name "$app_name")
  
  # Check if app is from Homebrew by examining the receipt
  if [ -f "/usr/local/Caskroom/${cask_name}/*/receipt.json" ] || \
     [ -f "/opt/homebrew/Caskroom/${cask_name}/*/receipt.json" ]; then
    echo "Skipping ${app_name}: already managed by Homebrew as ${cask_name}."
  else
    # Double-check cask name matches
    for installed_cask in "${installed_brew_casks[@]}"; do
      if [[ "$installed_cask" == "$cask_name" ]]; then
        echo "Skipping ${app_name}: appears to be managed by Homebrew as ${cask_name}."
        continue 2
      fi
    done
    filtered_apps+=("$app")
  fi
done

apps=("${filtered_apps[@]}")
total_apps=${#apps[@]}
echo "Proceeding with $total_apps apps not managed by Homebrew."

if [ $total_apps -eq 0 ]; then
  echo "No applications to process. Exiting."
  exit 0
fi

# Allow user to reorder apps if requested
if [ "$ORDER_MODE" = true ]; then
  reorder_apps
fi

# Process all apps
for ((i=1; i<=total_apps; i++)); do
  app="${apps[$i]}"
  echo ""
  echo "==============================================="
  echo "Processing (${i}/${total_apps}): $(get_app_name "$app")"
  echo "==============================================="
  process_app "$app"
  remaining=$((total_apps - i))
  echo "Apps left: $remaining"
done

# Summary
echo ""
echo "======================================================"
echo "  REPLACEMENT SUMMARY"
echo "======================================================"
echo "Total apps processed: $total_apps"
echo "Apps replaced with Homebrew versions: $replaced_count"

if (( ${#not_found_apps[@]} > 0 )); then
  echo ""
  echo "The following apps were not found in Homebrew's cask repository:"
  for app in "${not_found_apps[@]}"; do
    echo " - $app"
  done
  echo "Tip: Search for them manually with 'brew search <app-name>'"
fi

if (( ${#conflict_apps[@]} > 0 )); then
  echo ""
  echo "The following apps encountered installation conflicts:"
  for app in "${conflict_apps[@]}"; do
    echo " - $app"
  done
  echo "Tip: Try installing them manually with 'brew install --cask <cask-name>'"
fi
