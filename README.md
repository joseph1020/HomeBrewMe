# HomeBrewMe
Reinstall Apple MacOS Apps via Homebrew

This Zsh script automates the process of converting manually installed macOS applications (located in `/Applications`) into Homebrew-managed casks. It scans your `/Applications` folder, filters out apps already managed by Homebrew, compares installed app versions with the versions available in Homebrew’s cask repository, and (after displaying detailed brew info) prompts you for replacement. The script also supports interactive ordering, global decision options, and attempts to quit running apps before removal.

## Features

- **Automatic Filtering**
  - Scans the `/Applications` folder for `.app` bundles.
  - Retrieves the list of installed Homebrew casks using `brew list --cask -1 -l` and filters out apps that are already managed.

- **Version Comparison**
  - Extracts the installed version from each app’s `Info.plist`.
  - Retrieves the Homebrew version using relaxed JSON parsing (via Python 3) to handle control characters.

- **Interactive User Prompts**
  - Displays detailed `brew info --cask <cask_name>` before prompting.
  - Offers options for each app:
    - `y`: Replace this app.
    - `n`: Skip this app.
    - `A` (all yes): Replace all subsequent apps.
    - `F` (all no): Skip all subsequent apps.

- **Interactive Ordering**
  - Optionally reorder the processing list via the `--order` flag.

- **Graceful Removal**
  - Attempts to quit the app (using AppleScript) before removal.
  - Removes the app file-by-file and immediately falls back to `sudo rm -rf` if any removal fails.

- **Reporting**
  - At the end, reports apps not found in Homebrew’s cask repository and apps that encountered installation conflicts.

## Prerequisites

- **Operating System:** macOS
- **Shell:** Zsh
- **Tools:**
  - [Homebrew](https://brew.sh/)
  - [jq](https://stedolan.github.io/jq/)
  - [Python 3](https://www.python.org/)
  - `osascript` (pre-installed on macOS)

## Installation

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/joseph1020/HomeBrewMe.git
   cd HomeBrewMe
