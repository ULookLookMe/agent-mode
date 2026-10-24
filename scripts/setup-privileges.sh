#!/bin/zsh
# Creates the sudoers rule agentmode needs (exactly two pmset commands, design §7) and installs the
# LaunchAgent. Run it from a terminal: it asks for your administrator password once.
#
#   zsh setup-privileges.sh [--binary PATH] [--yes]
#   zsh setup-privileges.sh --uninstall [--binary PATH]
set -euo pipefail

rule_file=/etc/sudoers.d/agentmode
binary=""
uninstall=false
assume_yes=false

usage() {
    print "usage: zsh setup-privileges.sh [--binary PATH] [--yes]"
    print "       zsh setup-privileges.sh --uninstall [--binary PATH]"
}

while (( $# )); do
    case "$1" in
        --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
        --uninstall) uninstall=true; shift ;;
        --yes | -y) assume_yes=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) print -u2 "setup-privileges: unknown option '$1'"; usage >&2; exit 64 ;;
    esac
done

if [[ -z "$binary" ]]; then
    binary="$(command -v agentmode || true)"
fi
if [[ -z "$binary" || ! -x "$binary" ]]; then
    print -u2 "setup-privileges: agentmode not found; put it on your PATH or pass --binary PATH"
    exit 1
fi
# Absolute, but with symlinks kept: Homebrew's linked path must not turn into a Cellar path, which
# `agentmode install` refuses because it changes with every upgrade.
[[ "$binary" == /* ]] || binary="$PWD/$binary"

if $uninstall; then
    # `agentmode uninstall` needs the rule to restore SleepDisabled to 0, so the rule goes last.
    "$binary" uninstall
    sudo rm -f "$rule_file"
    sudo -k
    print "agentmode is uninstalled and the sudoers rule is removed"
    exit 0
fi

user="$(id -un)"
user_pattern='^[A-Za-z0-9_][A-Za-z0-9._-]*$'
if [[ ! "$user" =~ $user_pattern ]]; then
    print -u2 "setup-privileges: unexpected user name '$user'; create the rule by hand (see README)"
    exit 1
fi

rule="$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
print "agentmode needs this sudoers rule. It is the only thing agentmode runs as root:"
print -r -- "  $rule"
if ! $assume_yes; then
    if ! read -q "reply?Create $rule_file with it? [y/N] " < /dev/tty; then
        print
        print "Nothing changed."
        exit 1
    fi
    print
fi

# The file is written and checked as root in /etc/sudoers.d, which only root can write. sudo skips files
# whose name contains a dot, so the rule takes effect only with the final rename.
tmp="$rule_file.tmp"
print -r -- "$rule" | sudo tee "$tmp" > /dev/null
sudo chown root:wheel "$tmp"
sudo chmod 0440 "$tmp"
sudo visudo -cf "$tmp" > /dev/null
sudo grep -qxF -- "$rule" "$tmp"
sudo mv -f "$tmp" "$rule_file"
sudo visudo -c > /dev/null

# Forget the cached sudo session so the checks prove that no password is needed.
sudo -k
sudo -n -l /usr/bin/pmset -a disablesleep 0 > /dev/null
sudo -n -l /usr/bin/pmset -a disablesleep 1 > /dev/null
print "sudoers rule OK"

"$binary" install
