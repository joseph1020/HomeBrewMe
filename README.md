# HomeBrewMe

[![MIT License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-supported-lightgrey)
![Zsh](https://img.shields.io/badge/shell-Zsh-blue)

HomeBrewMe helps replace manually installed macOS applications with their Homebrew cask versions. It scans `/Applications`, checks for matching casks, and lets you review each replacement. Use dry-run mode to preview actions before making changes.

### Features

- Finds applications in `/Applications` that are not marked as Homebrew-managed.
- Compares installed app versions with available cask versions.
- Supports dry-run, interactive ordering, and verbose output.
- Prompts before replacing apps and summarizes results.

## Requirements

- macOS with Zsh
- [Homebrew](https://brew.sh/)
- `jq`
- Python 3
- `osascript` (included with macOS)

## Installation

```sh
git clone https://github.com/joseph1020/HomeBrewMe.git
cd HomeBrewMe
chmod +x HomeBrewMe.sh
```

## Usage

Run the script and follow the prompts:

```sh
./HomeBrewMe.sh
```

Preview without making changes, or use the other supported options:

```sh
./HomeBrewMe.sh --dry-run
./HomeBrewMe.sh --order
./HomeBrewMe.sh --verbose
./HomeBrewMe.sh --help
```

Options can be combined, for example `./HomeBrewMe.sh --dry-run --order --verbose`.

## Safety and behavior

The script asks before replacing each app. A replacement can quit the app, remove its existing `/Applications` bundle, and install the matching cask. Removal may request administrator access through `sudo`. `--dry-run` previews operations without carrying them out.

## Limitations

Only applications found in `/Applications` are scanned. An app without a matching Homebrew cask cannot be replaced automatically.

## License

HomeBrewMe is released under the MIT License. See [LICENSE](LICENSE).
