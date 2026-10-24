#!/bin/zsh
# Installs agentmode from a GitHub release: checks the Mac, downloads and verifies the binary, installs it,
# creates the sudoers rule and starts the background process.
#
#   curl -fsSL https://github.com/ULookLookMe/agent-mode/releases/latest/download/install.sh | zsh
#   curl -fsSL https://github.com/ULookLookMe/agent-mode/releases/latest/download/install.sh | zsh -s -- --uninstall
#
# Options: --version vX.Y.Z (default: latest), --prefix DIR (default: ~/.local/bin), --uninstall.
# Everything runs inside main, so a partial download never runs half a script.

main() {
    set -euo pipefail
    local repo="ULookLookMe/agent-mode"
    local version="${AGENTMODE_VERSION:-latest}"
    local prefix="${AGENTMODE_PREFIX:-$HOME/.local/bin}"
    local uninstall=false

    while (( $# )); do
        case "$1" in
            --version) version="${2:?--version needs a tag such as v0.1.0}"; shift 2 ;;
            --prefix) prefix="${2:?--prefix needs a folder}"; shift 2 ;;
            --uninstall) uninstall=true; shift ;;
            -h | --help)
                print "usage: install.sh [--version vX.Y.Z] [--prefix DIR] | --uninstall [--prefix DIR]"
                return 0
                ;;
            *) print -u2 "install.sh: unknown option '$1'"; return 64 ;;
        esac
    done
    local target="$prefix/agentmode"

    if $uninstall; then
        local installed="$target"
        [[ -x "$installed" ]] || installed="$(command -v agentmode || true)"
        if [[ -z "$installed" ]]; then
            print -u2 "install.sh: agentmode is not at $target or on your PATH. Run '<path>/agentmode uninstall' first,"
            print -u2 "then 'sudo rm /etc/sudoers.d/agentmode'. Nothing was changed."
            return 1
        fi
        # The rule goes last: uninstall needs it to set SleepDisabled back to 0.
        "$installed" uninstall
        sudo rm -f /etc/sudoers.d/agentmode
        sudo -k
        [[ "$installed" == "$target" ]] && rm -f "$target"
        print "agentmode is uninstalled."
        print "Optional cleanup: ~/Library/Application Support/agentmode, ~/.config/agentmode, ~/Library/Logs/agentmode*"
        return 0
    fi

    if [[ "$(uname -m)" != arm64 ]]; then
        print -u2 "install.sh: agentmode needs an Apple silicon Mac"
        return 1
    fi
    local macos="$(sw_vers -productVersion)"
    if (( ${macos%%.*} < 27 )); then
        print -u2 "install.sh: agentmode needs macOS 27 or later (this Mac runs $macos)"
        return 1
    fi

    local base
    if [[ "$version" == latest ]]; then
        base="https://github.com/$repo/releases/latest/download"
    else
        base="https://github.com/$repo/releases/download/$version"
    fi

    local tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" EXIT
    print "Downloading agentmode ($version)…"
    curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
    local name="$(awk '{print $2}' "$tmp/SHA256SUMS" | grep -E '^agentmode-v[0-9]+\.[0-9]+\.[0-9]+-macos-arm64\.tar\.gz$' | head -n 1)"
    if [[ -z "$name" ]]; then
        print -u2 "install.sh: the release has no macOS arm64 archive"
        return 1
    fi
    # curl sets no quarantine attribute, so Gatekeeper does not block the unsigned binary.
    curl -fsSL "$base/$name" -o "$tmp/$name"
    (cd "$tmp" && grep -F "  $name" SHA256SUMS | shasum -a 256 -c - > /dev/null)
    print "Checksum OK."
    tar -xzf "$tmp/$name" -C "$tmp"
    local folder="$tmp/${name%.tar.gz}"

    mkdir -p "$prefix"
    # install(1), never cp: it gives the file a new inode, so macOS does not kill the new binary.
    install -m 0755 "$folder/agentmode" "$target"
    print "Installed $("$target" --version) at $target."

    # -k ignores a cached sudo session, so the check proves that no password is needed.
    if sudo -k -n -l /usr/bin/pmset -a disablesleep 0 > /dev/null 2>&1 \
        && sudo -k -n -l /usr/bin/pmset -a disablesleep 1 > /dev/null 2>&1; then
        "$target" install
    else
        zsh "$folder/setup-privileges.sh" --binary "$target" < /dev/tty
    fi

    if [[ ":$PATH:" != *":$prefix:"* ]]; then
        local line="export PATH=\"$prefix:\$PATH\""
        [[ "$prefix" == "$HOME/.local/bin" ]] && line='export PATH="$HOME/.local/bin:$PATH"'
        if read -q "reply?Add $prefix to your PATH in ~/.zprofile? [y/N] " < /dev/tty; then
            print
            print -r -- "$line" >> "$HOME/.zprofile"
            print "Added. Open a new terminal window to use 'agentmode'."
        else
            print
            print "To use 'agentmode' by name, add this line to ~/.zprofile:"
            print -r -- "  $line"
        fi
    fi

    sleep 2
    "$target" status
    print
    print "Done. Turn it on with: agentmode on"
    print "Read the Safety section before closing the lid in a bag: https://github.com/$repo#safety"
}

main "$@"
