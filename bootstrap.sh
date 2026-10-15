#!/usr/bin/env bash
# bootstrap.sh - the start command on macOS and Linux. One file, then everything else comes
# by itself.
#
#   ./bootstrap.sh --repo https://github.com/<account>/personal-os-setup.git
#
# What it does, in this order:
#   1. makes sure git, gh (GitHub CLI) and PowerShell 7 are on the machine, with the package
#      manager of the system (Homebrew on macOS; apt or dnf on Linux, plus the Microsoft
#      package repository for PowerShell)
#   2. asks you to sign in to GitHub (gh auth login) - needed to use gh and to push
#   3. clones the repository to a folder you confirm
#   4. runs install.ps1 from that clone under pwsh
#
# It changes nothing outside the folder you choose and the programs it installs. It is the only
# shell script in this repository: everything else is PowerShell 7, on all three systems
# (decision D2). The repository address has no default on purpose - this file may be copied
# around before anyone is signed in, and an account name does not belong into a repository
# (see AGENTS.md, hard rule 1).

set -euo pipefail

REPO_URL="${PERSONAL_OS_REPO:-}"
DEST=""
ASSUME_YES=0
SKIP_INSTALL=0

usage() {
    cat <<'EOF'
bootstrap.sh - set up personal-os-setup on this machine

  --repo <url>     the git address of the repository
                   default: the environment variable PERSONAL_OS_REPO
  --dest <dir>     where to clone it (default: ~/personal-os-setup)
  --yes, -y        answer every question with yes
  --skip-install   install the tools and clone, but do not run install.ps1
  -h, --help       this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_URL="${2:-}"; shift 2 ;;
        --dest) DEST="${2:-}"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say()  { printf '\n== %s ==\n' "$1"; }
ok()   { printf '   OK   %s\n' "$1"; }
note() { printf '   ..   %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '%s [Y/n] ' "$1"
    read -r answer
    [ -z "$answer" ] || printf '%s' "$answer" | grep -qi '^y'
}

OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *) echo "this script supports macOS and Linux; on Windows use bootstrap.ps1" >&2; exit 1 ;;
esac

printf '\n== personal-os-setup bootstrap (%s) ==\n' "$PLATFORM"

# ---------------------------------------------------------------- 1. the tools
say "Tools: git, gh, PowerShell 7"
if [ "$PLATFORM" = "macos" ]; then
    if ! have brew; then
        note "Homebrew is missing (it is the package manager this repo uses on macOS)"
        if confirm "Install Homebrew now (it asks for your password)?"; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
    fi
    if have brew; then
        # Apple silicon puts brew in /opt/homebrew, Intel in /usr/local
        eval "$(brew shellenv)"
        brew list git >/dev/null 2>&1 || brew install git
        brew list gh >/dev/null 2>&1 || brew install gh
        # the formula is called "powershell" and installs the pwsh binary
        # (checked against https://formulae.brew.sh/api/formula/powershell.json, 2026-10-14)
        brew list powershell >/dev/null 2>&1 || brew install powershell
    fi
else
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        note "distribution: ${PRETTY_NAME:-unknown}"
    fi
    if have apt-get; then
        if ! have git || ! have curl; then
            sudo apt-get update
            sudo apt-get install -y git curl wget
        fi
        if ! have gh; then
            note "installing the GitHub CLI"
            sudo mkdir -p -m 755 /etc/apt/keyrings
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
            sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update
            sudo apt-get install -y gh
        fi
        if ! have pwsh; then
            note "installing PowerShell 7 from the Microsoft package repository"
            # shellcheck source=/dev/null
            if [ -r /etc/os-release ]; then . /etc/os-release; fi
            case "${ID:-}" in
                debian) MS_REPO="debian" ;;
                *)      MS_REPO="ubuntu" ;;
            esac
            wget -q "https://packages.microsoft.com/config/${MS_REPO}/${VERSION_ID:-22.04}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
            sudo dpkg -i /tmp/packages-microsoft-prod.deb
            rm -f /tmp/packages-microsoft-prod.deb
            sudo apt-get update
            sudo apt-get install -y powershell
        fi
    elif have dnf; then
        if ! have git || ! have curl; then sudo dnf install -y git curl wget; fi
        if ! have gh; then sudo dnf install -y gh; fi
        if ! have pwsh; then
            note "installing PowerShell 7 from the Microsoft package repository"
            majorver=9
            if [ -r /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                majorver="${VERSION_ID%%.*}"
            fi
            curl -sSL -o /tmp/packages-microsoft-prod.rpm "https://packages.microsoft.com/config/rhel/${majorver}/packages-microsoft-prod.rpm"
            sudo rpm -i /tmp/packages-microsoft-prod.rpm
            rm -f /tmp/packages-microsoft-prod.rpm
            sudo dnf install -y powershell
        fi
    else
        note "no apt-get and no dnf found - install git, gh and PowerShell 7 by hand"
        note "PowerShell 7: https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
    fi
fi

for t in git gh pwsh; do
    if have "$t"; then ok "$t is on PATH"; else note "$t is still missing"; fi
done
have git || { echo "git is missing - install it and start this script again" >&2; exit 1; }

# ------------------------------------------------------------- 2. github login
say "Sign in to GitHub"
if ! have gh; then
    note "the GitHub CLI (gh) is missing - clone the repository yourself and run install.ps1 in it"
elif gh auth status >/dev/null 2>&1; then
    ok "already signed in"
elif confirm "Sign in to GitHub now (a browser window opens)?"; then
    gh auth login --hostname github.com --git-protocol https --web
    ok "signed in"
else
    note "skipped - the repository cannot be cloned without a sign-in"
fi

# ------------------------------------------------------------------ 3. clone it
say "Get the repository"
if [ -z "$REPO_URL" ]; then
    printf '\nThis file does not carry the repository address.\n'
    printf 'You find the address in the browser after signing in, or in the personal.yaml of a machine you already set up.\n'
    printf 'Repository URL (https://github.com/<account>/personal-os-setup.git): '
    read -r REPO_URL
fi
[ -n "$REPO_URL" ] || { echo "no repository URL given" >&2; exit 1; }
[ -n "$DEST" ] || DEST="$HOME/personal-os-setup"

if [ -f "$DEST/install.ps1" ]; then
    ok "already there: $DEST"
else
    printf '   target: %s\n' "$DEST"
    if ! confirm "Clone the repository there?"; then echo "stopped by you" >&2; exit 1; fi
    if have gh; then gh repo clone "$REPO_URL" "$DEST"; else git clone "$REPO_URL" "$DEST"; fi
    ok "cloned to $DEST"
fi

# ------------------------------------------------------------------- 4. install
if [ "$SKIP_INSTALL" -eq 1 ]; then
    say "Skipped install.ps1 (--skip-install)"
    exit 0
fi
say "Install (install.ps1)"
have pwsh || { echo "PowerShell 7 is missing - install it and run install.ps1 in the clone yourself" >&2; exit 1; }
exec pwsh -NoProfile -File "$DEST/install.ps1"
