# HomeBrewMe

Convert manually installed macOS applications to Homebrew-managed casks.

## Overview

This Zsh script automates the process of replacing manually installed macOS applications with their Homebrew cask equivalents. It scans your `/Applications` folder, identifies apps that aren't already managed by Homebrew, compares installed versions with available Homebrew versions, and guides you through the replacement process.

## Features

- **Smart Application Detection**
  - Scans the `/Applications` folder for manually installed apps
  - Intelligently identifies corresponding Homebrew casks
  - Detects apps already managed by Homebrew using receipt files

- **Version Comparison**
  - Extracts and compares app versions using semantic versioning rules
  - Indicates when installed versions are newer, older, or the same as Homebrew versions
  - Makes informed replacement recommendations based on version differences

- **Flexible User Options**
  - Dry run mode to preview changes without making modifications
  - Interactive ordering to prioritize which apps to process first
  - Verbose mode for detailed information about each app

- **Intelligent App Handling**
  - Gracefully quits running applications before removal
  - Handles permissions issues with escalation to sudo when necessary
  - Manages file-by-file removal for better security and reliability

- **Comprehensive Reporting**
  - Detailed summary of all operations performed
  - Lists apps not found in Homebrew's cask repository
  - Reports apps that encountered installation conflicts

## Prerequisites

- **Operating System:** macOS
- **Shell:** Zsh
- **Required Tools:**
  - [Homebrew](https://brew.sh/)
  - [jq](https://stedolan.github.io/jq/) (`brew install jq`)
  - [Python 3](https://www.python.org/) (`brew install python`)
  - `osascript` (pre-installed on macOS)

## Installation

1. **Clone the Repository:**
   ```bash
   git clone https://github.com/joseph1020/HomeBrewMe.git
   cd HomeBrewMe
   ```

2. **Make the Script Executable:**
   ```bash
   chmod +x homebrew-me.zsh
   ```

## Usage

### Basic Usage

Run the script with no arguments to scan applications and interactively replace them:

```bash
./homebrew-me.zsh
```

### Command Line Options

- **Dry Run Mode:**
  ```bash
  ./homebrew-me.zsh --dry-run
  ```
  Shows what would be done without making any changes.

- **Interactive Ordering:**
  ```bash
  ./homebrew-me.zsh --order
  ```
  Allows you to choose which apps to process first.

- **Verbose Output:**
  ```bash
  ./homebrew-me.zsh --verbose
  ```
  Shows more detailed information during processing.

- **Help:**
  ```bash
  ./homebrew-me.zsh --help
  ```
  Displays usage information and options.

- **Combine Options:**
  ```bash
  ./homebrew-me.zsh --dry-run --order --verbose
  ```

### Interactive Prompts

For each app, you'll be prompted with the following options:

- `y`: Replace this app with the Homebrew version
- `n`: Skip this app
- `A`: Replace all subsequent apps (yes to all)
- `F`: Skip all subsequent apps (no to all)

## How It Works

1. **Discovery Phase:**
   - Scans `/Applications` for `.app` bundles
   - Identifies which apps are not managed by Homebrew

2. **Analysis Phase:**
   - Derives the canonical Homebrew cask name for each app
   - Extracts and compares version information

3. **Processing Phase:**
   - Prompts for user decision based on version comparison
   - Quits the app if it's running
   - Removes the manually installed version
   - Installs the Homebrew cask version

4. **Summary Phase:**
   - Reports successful replacements
   - Lists apps not found in Homebrew
   - Reports any installation conflicts

## Advanced Features

- **Version Comparison Logic:**
  The script implements semantic version comparison to accurately compare app versions, even when they use different formatting conventions.

- **Cask Name Derivation:**
  Multiple strategies are used to derive the correct Homebrew cask name from the app name, including handling special cases like "Classic" apps.

- **Permission Handling:**
  The script tries user-level file removal first, then escalates to sudo only when necessary.

## Troubleshooting

- **App Not Found in Homebrew:**
  If an app is not found, try searching for it manually with `brew search <app-name>` as it might have a different cask name.

- **Installation Conflicts:**
  For apps that encounter conflicts during installation, try installing them manually with `brew install --cask <cask-name>`.

- **Permission Issues:**
  If you encounter permission issues, ensure you have sudo privileges on your system.

## Contributing

Contributions are welcome! Feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
