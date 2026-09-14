#!/bin/zsh
# brew-app-replacer.sh
# A script to replace manually installed Mac applications with homebrew cask versions

# === Initialization ===
MAPPING_FILE="brew_mappings.txt"
if [[ ! -f "$MAPPING_FILE" ]]; then
    touch "$MAPPING_FILE"
fi

# Initialize global variables
global_decision=""
typeset -A managed_map
typeset -A installed_brew_map
not_found_apps=()
conflict_apps=()
replaced_count=0

# Default mode settings
DRY_RUN=false
ORDER_MODE=false
VERBOSE=false
BATCH_MODE=false

# === Process Command-Line Options ===
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            echo "Dry run mode enabled (no actual changes will be made)"
            ;;
        --order)
            ORDER_MODE=true
            echo "Order mode enabled"
            ;;
        --verbose)
            VERBOSE=true
            echo "Verbose mode enabled"
            ;;
        --batch)
            BATCH_MODE=true
            echo "Batch mode enabled"
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --dry-run    Simulate operations without making changes"
            echo "  --order      Enable custom app processing order"
            echo "  --verbose    Display detailed information"
            echo "  --batch      Process all apps before prompting for manual mapping"
            echo "  --help       Display this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ "$BATCH_MODE" == true ]]; then
    echo "Interactive Mapping Mode: Batch"
else
    echo "Interactive Mapping Mode: Immediate"
fi

# === Check for Required Commands ===
for cmd in brew jq python3 osascript; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it and try again."
        exit 1
    fi
done

# === Custom timeout function replacement ===
# macOS-compatible alternative to GNU timeout
mac_timeout() {
    local timeout_duration=$1
    shift
    (
        "$@" &
        local cmd_pid=$!
        (
            sleep ${timeout_duration%s}
            kill -0 $cmd_pid 2>/dev/null && kill $cmd_pid
        ) &
        local timer_pid=$!
        wait $cmd_pid
        kill -0 $timer_pid 2>/dev/null && kill $timer_pid
    )
}

# === Load Existing Mappings ===
if [[ -f "$MAPPING_FILE" ]]; then
    while IFS=, read -r app_folder brew_cask artifact || [[ -n "$app_folder" ]]; do
        if [[ -n "$app_folder" && -n "$brew_cask" && -n "$artifact" ]]; then
            normalized_app=$(echo "$app_folder" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
            managed_map[$normalized_app]="$brew_cask,$artifact"
        fi
    done < "$MAPPING_FILE"
fi

# === Define Helper Functions ===
normalize() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

update_brew_mapping() {
    local app_folder="$1"
    local brew_cask="$2"
    local artifact="$3"

    # Check if mapping already exists
    local exists=false
    if [[ -f "$MAPPING_FILE" ]]; then
        while IFS=, read -r existing_app existing_cask existing_artifact || [[ -n "$existing_app" ]]; do
            if [[ "$existing_app" == "$app_folder" && "$existing_cask" == "$brew_cask" ]]; then
                exists=true
                break
            fi
        done < "$MAPPING_FILE"
    fi

    if [[ "$exists" == false ]]; then
        echo "$app_folder,$brew_cask,$artifact" >> "$MAPPING_FILE"
    fi
}

get_app_name() {
    local app_path="$1"
    if [[ -z "$app_path" ]]; then
        echo "Unknown"
        return 1
    fi
    basename "$app_path" .app
}

check_cask_exists() {
    brew info --cask "$1" &>/dev/null
    return $?
}

# === Candidate Determination Functions ===
get_cask_name() {
    local app_name="$1"
    # Remove trailing numbers and spaces
    local candidate=$(echo "$app_name" | sed -E 's/[0-9]+$//g' | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    if check_cask_exists "$candidate"; then
        echo "$candidate"
        return 0
    fi

    # Try alternative format (remove spaces and lowercase)
    candidate=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    if check_cask_exists "$candidate"; then
        echo "$candidate"
        return 0
    fi

    # Try with full app name
    candidate=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if check_cask_exists "$candidate"; then
        echo "$candidate"
        return 0
    fi

    return 1
}

get_brew_artifact_app_name() {
    local cask="$1"
    local json_output

    # Use mac_timeout to prevent hanging
    json_output=$(mac_timeout 5s brew info --cask --json=v2 "$cask" 2>/dev/null)

    if [[ -z "$json_output" ]]; then
        echo "(none)"
        return 1
    fi

    local artifact=$(echo "$json_output" | jq -r '.casks[0].artifacts[] | select(.[0] | test("\\.app$")) | .[0]' 2>/dev/null | sed 's/\.app$//')

    if [[ -z "$artifact" || "$artifact" == "null" ]]; then
        echo "(none)"
        return 1
    fi

    echo "$artifact"
    return 0
}

get_brew_info_app_name() {
    local cask="$1"
    local json_output

    # Use mac_timeout to prevent hanging
    json_output=$(mac_timeout 5s brew info --cask --json=v2 "$cask" 2>/dev/null)

    if [[ -z "$json_output" ]]; then
        echo "(none)"
        return 1
    fi

    # Try to extract name from json
    local name=$(echo "$json_output" | jq -r '.casks[0].name' 2>/dev/null)

    if [[ -z "$name" || "$name" == "null" ]]; then
        echo "(none)"
        return 1
    fi

    echo "$name"
    return 0
}

get_brew_version() {
    local cask="$1"
    local json_output

    # Use mac_timeout to prevent hanging
    json_output=$(mac_timeout 5s brew info --cask --json=v2 "$cask" 2>/dev/null)

    if [[ -z "$json_output" ]]; then
        echo "unknown"
        return 1
    fi

    local version=$(echo "$json_output" | jq -r '.casks[0].version' 2>/dev/null)

    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "unknown"
        return 1
    fi

    echo "$version"
    return 0
}

find_brew_cask_for_app() {
    local app_name="$1"
    local candidate=$(get_cask_name "$app_name")

    if [[ -z "$candidate" ]]; then
        return 1
    fi

    local artifact=$(get_brew_artifact_app_name "$candidate")

    if [[ "$artifact" == "(none)" ]]; then
        artifact=$(get_brew_info_app_name "$candidate")
        if [[ "$artifact" == "(none)" ]]; then
            return 1
        fi
    fi

    # Check if app_name matches (or contains) artifact or vice versa
    local norm_app=$(normalize "$app_name")
    local norm_artifact=$(normalize "$artifact")

    if [[ "$norm_app" == "$norm_artifact" || "$norm_app" == *"$norm_artifact"* || "$norm_artifact" == *"$norm_app"* ]]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

# === Fuzzy Matching for Interactive Mapping ===
fuzzy_match_cask() {
    local app="$1"
    local norm_app=$(normalize "$app")
    local all_casks=$(mac_timeout 10s brew search --casks "" 2>/dev/null | tr ' ' '\n')

    # Python-based fuzzy matching
    python3 -c "
import sys
import difflib

app = '$norm_app'
casks = '''$all_casks'''.splitlines()

matches = difflib.get_close_matches(app, [c.lower() for c in casks], n=5, cutoff=0.6)
for match in matches:
    for cask in casks:
        if cask.lower() == match:
            print(cask)
            break
"
}

# === Interactive Mapping Functions ===
interactive_mapping_for_app() {
    local app="$1"
    if [[ -z "$app" || ! -d "$app" ]]; then
        echo "Invalid app path: '$app'"
        return 1
    fi

    local folder=$(get_app_name "$app")
    echo "Unmatched app: $folder"

    # Direct search
    local direct_search_candidates=()
    local direct_candidate=$(get_cask_name "$folder")
    if [[ -n "$direct_candidate" ]]; then
        direct_search_candidates+=("$direct_candidate")
    fi

    # Try with dashes
    local dashed_candidate=$(echo "$folder" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
    if check_cask_exists "$dashed_candidate"; then
        direct_search_candidates+=("$dashed_candidate")
    fi

    # Fuzzy match
    local fuzzy_candidates=($(fuzzy_match_cask "$folder"))

    # Combine and deduplicate
    local unique_candidates=()
    local all_candidates=("${direct_search_candidates[@]}" "${fuzzy_candidates[@]}")

    for candidate in "${all_candidates[@]}"; do
        local is_duplicate=false
        for unique in "${unique_candidates[@]}"; do
            if [[ "$unique" == "$candidate" ]]; then
                is_duplicate=true
                break
            fi
        done

        if [[ "$is_duplicate" == false ]]; then
            unique_candidates+=("$candidate")
        fi
    done

    local brew_cask_input=""

    if [[ ${#unique_candidates[@]} -gt 0 ]]; then
        echo "Candidates for '$folder':"
        for i in {1..${#unique_candidates[@]}}; do
            local cask="${unique_candidates[$i-1]}"
            if [[ "$VERBOSE" == true ]]; then
                local version=$(get_brew_version "$cask")
                local artifact=$(get_brew_artifact_app_name "$cask")
                if [[ "$artifact" == "(none)" ]]; then
                    artifact=$(get_brew_info_app_name "$cask")
                fi
                echo "  $i. $cask (Version: $version, Artifact: $artifact.app)"
            else
                echo "  $i. $cask"
            fi
        done

        echo -n "Enter candidate number (or custom Brew cask) for $folder, or 0 to skip: "
        read user_input
        user_input=$(echo "$user_input" | xargs)

        if [[ "$user_input" =~ ^[0-9]+$ ]]; then
            if [[ "$user_input" -eq 0 ]]; then
                return 1
            elif [[ "$user_input" -le ${#unique_candidates[@]} ]]; then
                brew_cask_input="${unique_candidates[$user_input-1]}"
                brew_cask_input=$(echo "$brew_cask_input" | sed 's/\.rb$//')
            else
                echo "Invalid number."
                return 1
            fi
        else
            brew_cask_input=$(echo "$user_input" | xargs | sed 's/\.rb$//')
        fi
    else
        echo -n "No candidate suggestion available for $folder. Enter a Brew cask or leave blank to skip: "
        read brew_cask_input
        brew_cask_input=$(echo "$brew_cask_input" | xargs)
        if [[ -z "$brew_cask_input" ]]; then
            return 1
        fi
    fi

    if [[ -n "$brew_cask_input" ]]; then
        if ! check_cask_exists "$brew_cask_input"; then
            echo "Warning: The cask '$brew_cask_input' doesn't seem to exist. Adding anyway."
        fi

        local artifact=$(get_brew_artifact_app_name "$brew_cask_input")
        if [[ "$artifact" == "(none)" ]]; then
            artifact=$(get_brew_info_app_name "$brew_cask_input")
        fi

        update_brew_mapping "$folder" "$brew_cask_input" "$artifact"
        echo "Mapping added: $folder -> $brew_cask_input (Artifact: $artifact.app)"
        echo "$brew_cask_input"
        return 0
    fi

    return 1
}

match_unmatched_apps() {
    if [[ ${#not_found_apps[@]} -eq 0 ]]; then
        return
    fi

    echo "Processing unmatched apps..."
    for app in "${not_found_apps[@]}"; do
        if [[ -z "$app" || ! -d "$app" ]]; then
            echo "Skipping invalid app path: '$app'"
            continue
        fi
        interactive_mapping_for_app "$app"
        echo "----------------------------------------"
    done
}

# === Version Comparison ===
compare_versions() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "unknown" || "$v2" == "unknown" ]]; then
        echo "unknown"
        return
    fi

    # Split versions into arrays
    local v1_parts=(${(s:.:)v1})
    local v2_parts=(${(s:.:)v2})

    # Compare each part
    local max_length=$((${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]}))

    for (( i=1; i<=max_length; i++ )); do
        local part1=${v1_parts[$i]:-0}
        local part2=${v2_parts[$i]:-0}

        # Handle non-numeric parts
        if ! [[ "$part1" =~ ^[0-9]+$ ]]; then part1=0; fi
        if ! [[ "$part2" =~ ^[0-9]+$ ]]; then part2=0; fi

        if (( part1 > part2 )); then
            echo "newer"
            return
        elif (( part1 < part2 )); then
            echo "older"
            return
        fi
    done

    echo "same"
}

# === Quit and Removal Functions ===
quit_app() {
    local app_name="$1"

    if pgrep -f "$app_name" > /dev/null; then
        echo "Attempting to quit $app_name..."
        osascript -e "tell application \"$app_name\" to quit" 2>/dev/null

        # Wait up to 5 seconds for app to quit
        for (( i=0; i<5; i++ )); do
            if ! pgrep -f "$app_name" > /dev/null; then
                return 0
            fi
            sleep 1
        done

        # If still running, prompt user
        if pgrep -f "$app_name" > /dev/null; then
            echo "$app_name is still running. Force continue? (y/n)"
            read continue_choice
            if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
                return 1
            fi
        fi
    fi

    return 0
}

remove_app() {
    local app_path="$1"

    if [[ "$DRY_RUN" == false ]]; then
        echo "Removing $app_path..."

        # Try to remove with regular permissions
        if rm -rf "$app_path" 2>/dev/null; then
            return 0
        fi

        # If that fails, try with sudo
        echo "Removal requires admin privileges."
        if sudo rm -rf "$app_path"; then
            return 0
        else
            echo "Failed to remove $app_path"
            return 1
        fi
    else
        echo "Dry run: Would remove $app_path"
        return 0
    fi
}

# === Process an Individual App ===
process_app() {
    local app_path="$1"

    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        echo "Error: Invalid app path: '$app_path'"
        return 1
    fi

    local app_name=$(get_app_name "$app_path")
    echo "Processing: $app_name"

    local candidate_cask=$(find_brew_cask_for_app "$app_name")

    if [[ -z "$candidate_cask" ]]; then
        if [[ "$BATCH_MODE" == false ]]; then
            candidate_cask=$(interactive_mapping_for_app "$app_path")
            if [[ -z "$candidate_cask" ]]; then
                echo "Skip $app_name"
                return 1
            fi
        else
            not_found_apps+=("$app_path")
            return 1
        fi
    fi

    local cask_name="$candidate_cask"
    echo "$app_name is matched to Brew cask: $cask_name"

    # Check if there's a manual mapping
    local normalized_app=$(normalize "$app_name")
    if [[ -n "${managed_map[$normalized_app]}" ]]; then
        local manual_mapping=${managed_map[$normalized_app]}
        cask_name=$(echo "$manual_mapping" | cut -d ',' -f 1)
        echo "Using manual mapping to $cask_name"
    fi

    # Get versions
    local installed_version="unknown"
    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        installed_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null)
        if [[ -z "$installed_version" ]]; then
            installed_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_path/Contents/Info.plist" 2>/dev/null)
        fi
        if [[ -z "$installed_version" ]]; then
            installed_version="unknown"
        fi
    fi

    local brew_version=$(get_brew_version "$cask_name")

    echo "Installed version: $installed_version"
    echo "Brew version: $brew_version"

    if [[ "$VERBOSE" == true ]]; then
        echo "Brew info for $cask_name:"
        mac_timeout 5s brew info --cask "$cask_name"
    fi

    local version_comparison=$(compare_versions "$installed_version" "$brew_version")

    if [[ "$version_comparison" == "same" ]]; then
        echo "Versions match; skipping replacement"
        local artifact=$(get_brew_artifact_app_name "$cask_name")
        if [[ "$artifact" == "(none)" ]]; then
            artifact=$(get_brew_info_app_name "$cask_name")
        fi
        update_brew_mapping "$app_name" "$cask_name" "$artifact"
        return 0
    fi

    # Prompt user for decision
    local prompt_text=""
    if [[ "$version_comparison" == "newer" ]]; then
        prompt_text="Your installed version of $app_name ($installed_version) is newer than the brew version ($brew_version)."
    elif [[ "$version_comparison" == "older" ]]; then
        prompt_text="Your installed version of $app_name ($installed_version) is older than the brew version ($brew_version)."
    else
        prompt_text="Cannot determine version relationship between your $app_name ($installed_version) and brew version ($brew_version)."
    fi

    local user_choice=""
    if [[ -n "$global_decision" ]]; then
        user_choice="$global_decision"
        # Always display the prompt text in verbose mode
        if [[ "$VERBOSE" == true ]]; then
            echo "$prompt_text"
            echo "Using global decision: $global_decision"
        fi
    else
        echo "$prompt_text"
        echo -n "Replace with Brew cask version? [y/n/all/none]: "
        read user_choice

        if [[ "$user_choice" == "all" ]]; then
            global_decision="y"
            user_choice="y"
            echo "Applied decision to all remaining apps"
        elif [[ "$user_choice" == "none" ]]; then
            global_decision="n"
            user_choice="n"
            echo "Skipping all remaining apps"
        fi
    fi

    if [[ "$user_choice" == "y" || "$user_choice" == "Y" ]]; then
        if ! quit_app "$app_name"; then
            echo "Failed to quit $app_name. Skipping replacement."
            return 1
        fi

        if ! remove_app "$app_path"; then
            echo "Failed to remove $app_path. Skipping replacement."
            return 1
        fi

        if [[ "$DRY_RUN" == false ]]; then
            echo "Installing $cask_name via Homebrew..."
            if ! mac_timeout 300s brew install --cask "$cask_name"; then
                echo "Failed to install $cask_name"
                conflict_apps+=("$app_name")
                return 1
            else
                echo "Successfully replaced $app_name with Brew cask $cask_name"
                replaced_count=$((replaced_count + 1))
                local artifact=$(get_brew_artifact_app_name "$cask_name")
                if [[ "$artifact" == "(none)" ]]; then
                    artifact=$(get_brew_info_app_name "$cask_name")
                fi
                update_brew_mapping "$app_name" "$cask_name" "$artifact"
            fi
        else
            echo "Dry run: Would install $cask_name"
        fi
    else
        echo "Skipping replacement for $app_name"
        local artifact=$(get_brew_artifact_app_name "$cask_name")
        if [[ "$artifact" == "(none)" ]]; then
            artifact=$(get_brew_info_app_name "$cask_name")
        fi
        update_brew_mapping "$app_name" "$cask_name" "$artifact"
    fi

    return 0
}

# Function to reorder apps (not fully implemented)
reorder_apps() {
    echo "Order mode is enabled but not fully implemented"
    # Placeholder for custom app ordering logic
}

# === Main Execution ===

echo "======================================================"
echo "Brew App Replacer"
echo "Replace manually installed apps with Homebrew casks"
if [[ "$DRY_RUN" == true ]]; then
    echo "MODE: DRY RUN (no actual changes will be made)"
else
    echo "MODE: LIVE (changes will be made)"
fi
echo "======================================================"

# Scan /Applications for .app directories
echo "Scanning /Applications for apps..."
apps=(/Applications/*.app(N))  # Adding (N) to ignore empty globs
total_apps=${#apps[@]}
echo "Found $total_apps applications in /Applications."

# Build installed_brew_map
echo "Building list of installed Homebrew casks..."
# Use a temporary file to safely collect artifacts
temp_cask_file=$(mktemp)

brew list --cask > "$temp_cask_file" &
brew_pid=$!
(
    sleep 30
    if kill -0 $brew_pid 2>/dev/null; then
        kill $brew_pid
        echo "Warning: brew list command timed out, proceeding with partial results"
    fi
) &
wait_pid=$!
wait $brew_pid 2>/dev/null
kill $wait_pid 2>/dev/null

if [[ -s "$temp_cask_file" ]]; then
    installed_casks=($(cat "$temp_cask_file"))
    total_casks=${#installed_casks[@]}
    echo "Found $total_casks installed Homebrew casks."

    # Process casks with progress indicator
    for ((i=1; i<=total_casks; i++)); do
        cask="${installed_casks[$i-1]}"
        # Print status update for every cask in verbose mode, otherwise every 10th
        if [[ "$VERBOSE" == true || $(($i % 10)) -eq 0 || $i -eq 1 || $i -eq $total_casks ]]; then
            echo "Processing cask $i of $total_casks: $cask"
        fi

        # Get artifact with timeout to prevent hanging
        artifact=$(mac_timeout 5s get_brew_artifact_app_name "$cask" 2>/dev/null)
        if [[ -z "$artifact" || "$artifact" == "(none)" ]]; then
            artifact=$(mac_timeout 5s get_brew_info_app_name "$cask" 2>/dev/null)
        fi

        if [[ -n "$artifact" && "$artifact" != "(none)" ]]; then
            installed_brew_map[$(normalize "$artifact")]="$cask"
            if [[ "$VERBOSE" == true ]]; then
                echo "  - Mapped $artifact to $cask"
            fi
        elif [[ "$VERBOSE" == true ]]; then
            echo "  - No artifact found for $cask"
        fi
    done
    echo "Cask processing complete."
else
    echo "No installed Homebrew casks found or brew command failed."
fi

rm -f "$temp_cask_file"

# Filter out apps already managed
filtered_apps=()
for app in "${apps[@]}"; do
    # Skip if app doesn't exist or is invalid
    if [[ -z "$app" || ! -d "$app" ]]; then
        continue
    fi

    app_name=$(get_app_name "$app")
    normalized_app=$(normalize "$app_name")

    if [[ -n "${managed_map[$normalized_app]}" ]]; then
        echo "Skipping $app_name: already in mapping file."
    elif [[ -n "${installed_brew_map[$normalized_app]}" ]]; then
        echo "Skipping $app_name: already managed by Homebrew."
    else
        filtered_apps+=("$app")
    fi
done

apps=("${filtered_apps[@]}")
total_apps=${#apps[@]}
echo "Proceeding with $total_apps apps not managed by Brew."

if [[ "$ORDER_MODE" == true ]]; then
    reorder_apps
fi

# Process each app
for ((i=1; i<=total_apps; i++)); do
    app_path="${apps[$i-1]}"

    # Skip if app doesn't exist or is invalid
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        echo "Skipping invalid app path at index $i"
        continue
    fi

    echo ""
    echo "Processing ($i/$total_apps): $(get_app_name "$app_path")"
    process_app "$app_path"
    echo "Apps left: $((total_apps - i))"
    echo "----------------------------------------"
done

# If batch mode, run interactive mapping for unmatched apps
if [[ "$BATCH_MODE" == true && ${#not_found_apps[@]} -gt 0 ]]; then
    echo ""
    echo "Beginning interactive mapping for unmatched apps..."
    match_unmatched_apps
fi

# Reformat mapping file to replace any legacy "art=" with "Artifact="
if [[ -f "$MAPPING_FILE" ]]; then
    sed -i '' 's/[Aa]rt=/Artifact=/g' "$MAPPING_FILE" 2>/dev/null || true
fi

# === Final Summary ===
echo ""
echo "======================================================"
echo "Replacement Summary:"
echo "Total apps processed: $total_apps"
echo "Apps replaced with Brew casks: $replaced_count"

if [[ ${#not_found_apps[@]} -gt 0 ]]; then
    echo "Apps not matched ($((${#not_found_apps[@]}))):"
    for app in "${not_found_apps[@]}"; do
        if [[ -n "$app" && -d "$app" ]]; then
            echo "  - $(get_app_name "$app")"
        fi
    done
fi

if [[ ${#conflict_apps[@]} -gt 0 ]]; then
    echo "Apps with installation conflicts ($((${#conflict_apps[@]}))):"
    for app in "${conflict_apps[@]}"; do
        echo "  - $app"
    done
fi

# Print current mappings
echo ""
echo "Current mappings:"
if [[ -f "$MAPPING_FILE" ]]; then
    while IFS=, read -r app_folder brew_cask artifact || [[ -n "$app_folder" ]]; do
        artifact_display="$artifact.app"
        if [[ -z "$artifact" ]]; then
            artifact_display="(none)"
        fi
        echo "App: $app_folder, Brew cask: $brew_cask, Artifact: $artifact_display"
    done < "$MAPPING_FILE"
fi

echo ""
echo "Process completed."
