#!/bin/sh
set -eu

app_version=3.8.2
cli_version=3.9.1
releases=https://github.com/surajmandalcell/switch/releases/download
fail() { printf 'Switch: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Install $1 and try again."; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) platform=darwin-arm64 ;;
  Linux/x86_64)
    platform=linux-x86_64
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || fail 'Linux requires glibc 2.38 or later.'
    printf '%s\n' "$libc" | awk '$1 == "glibc" && $2 ~ /^[0-9]+[.][0-9]+$/ {split($2,v,"."); ok=(v[1]+0>2 || (v[1]+0==2 && v[2]+0>=38))} END {exit !ok}' || fail 'Linux requires glibc 2.38 or later (for example, Ubuntu 24.04).'
    ;;
  *) fail 'Supported systems: Apple Silicon macOS and x86_64 Linux.' ;;
esac
for command in curl tar awk mktemp; do need "$command"; done
if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1" | awk '{print $1}'; }
else
  need shasum
  checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

bin_dir="$HOME/.local/bin"
app_dir="$HOME/Applications"
command_path="$bin_dir/ai-manager"
alias_path="$bin_dir/switch"
package_dir="${XDG_DATA_HOME:-$HOME/.local/share}/switch/cli/$cli_version"
if [ -e "$alias_path" ] || [ -L "$alias_path" ]; then
  [ -L "$alias_path" ] && [ "$(readlink "$alias_path")" = ai-manager ] || fail "Refusing to replace an unrelated command: $alias_path"
fi
[ ! -d "$command_path" ] || fail "The command destination is a directory: $command_path"
if [ -L "$command_path" ]; then
  case "$(readlink "$command_path")" in
    "${XDG_DATA_HOME:-$HOME/.local/share}/switch/cli/"*/ai-manager) ;;
    *) fail "Refusing to replace a linked command: $command_path" ;;
  esac
fi

if [ "$platform" = darwin-arm64 ]; then
  for command in ditto codesign spctl ps; do need "$command"; done
  [ "$(sw_vers -productVersion | cut -d . -f 1)" -ge 14 ] || fail 'macOS 14 or later is required.'
  [ ! -L "$app_dir/Switch.app" ] || fail 'Refusing to replace a linked Switch.app.'
  if [ -e "$app_dir/Switch.app" ]; then
    if ps -axww -o comm= | awk -v program="$app_dir/Switch.app/Contents/MacOS/AIManager" '$0 == program {found=1} END {exit !found}'; then
      fail 'Quit Switch before installing its update.'
    fi
    codesign --verify --deep --strict "$app_dir/Switch.app" || fail 'The existing Switch.app has an invalid signature.'
    codesign -d -r- "$app_dir/Switch.app" 2>&1 | grep -F 'GF57JXJF5A' >/dev/null || fail 'Refusing to replace an app from another developer.'
  fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/switch-install.XXXXXX")
temporary_binary=
temporary_alias=
staged_package=
staged_app=
previous_app=
cleanup() {
  [ -z "$temporary_binary" ] || rm -f "$temporary_binary"
  [ -z "$temporary_alias" ] || rm -f "$temporary_alias"
  [ -z "$staged_package" ] || rm -rf "$staged_package"
  if [ -n "$previous_app" ] && [ -e "$previous_app" ] && [ ! -e "$app_dir/Switch.app" ]; then
    mv "$previous_app" "$app_dir/Switch.app"
  fi
  [ -z "$staged_app" ] || rm -rf "$staged_app"
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
download() { curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 "$1" -o "$2"; }
verify() {
  expected=$(awk -v name="$2" '$2 == name {print $1}' "$3")
  [ "${#expected}" -eq 64 ] && [ "$(checksum "$1")" = "$expected" ] || fail "Checksum verification failed: $2"
}

archive="Switch-cli-v$cli_version-$platform.tar.gz"
download "$releases/cli-v$cli_version/$archive" "$work/$archive"
download "$releases/cli-v$cli_version/checksums.txt" "$work/cli-checksums.txt"
verify "$work/$archive" "$archive" "$work/cli-checksums.txt"
tar -tzf "$work/$archive" | awk 'BEGIN {ok=1} $0 != "ai-manager" && $0 != "LICENSE" && $0 != "SWIFT-LICENSE.txt" && $0 !~ /^[A-Za-z0-9_-]+[.]so([.][0-9]+)*$/ {ok=0} END {exit !ok}' || fail 'The CLI archive has unexpected contents.'
mkdir "$work/cli"
tar -xzf "$work/$archive" -C "$work/cli"
[ -f "$work/cli/ai-manager" ] && [ ! -L "$work/cli/ai-manager" ] || fail 'The CLI archive does not contain a regular binary.'
chmod 755 "$work/cli/ai-manager"
if [ "$platform" = darwin-arm64 ]; then
  codesign --verify --strict "$work/cli/ai-manager"
  codesign -d -r- "$work/cli/ai-manager" 2>&1 | grep -F 'GF57JXJF5A' >/dev/null || fail 'The CLI has an unexpected developer signature.'
fi
[ "$("$work/cli/ai-manager" --version)" = "Switch $cli_version" ] || fail 'The downloaded CLI version does not match.'

if [ "$platform" = darwin-arm64 ]; then
  app_archive="Switch-v$app_version-mac-arm64.zip"
  download "$releases/v$app_version/$app_archive" "$work/$app_archive"
  download "$releases/v$app_version/checksums-v$app_version.txt" "$work/app-checksums.txt"
  verify "$work/$app_archive" "$app_archive" "$work/app-checksums.txt"
  ditto -x -k "$work/$app_archive" "$work/app"
  [ -d "$work/app/Switch.app" ] && [ ! -L "$work/app/Switch.app" ] || fail 'The download does not contain Switch.app.'
  codesign --verify --deep --strict "$work/app/Switch.app"
  spctl --assess --type execute "$work/app/Switch.app"
  codesign -d -r- "$work/app/Switch.app" 2>&1 | grep -F 'GF57JXJF5A' >/dev/null || fail 'The app has an unexpected developer signature.'
fi

mkdir -p "$bin_dir"
temporary_binary=$(mktemp "$bin_dir/.ai-manager.XXXXXX")
temporary_alias="$temporary_binary.switch"
rm "$temporary_binary"
mkdir -p "$(dirname "$package_dir")"
if [ -e "$package_dir" ] || [ -L "$package_dir" ]; then
  [ ! -L "$package_dir" ] && diff -r "$work/cli" "$package_dir" >/dev/null || fail 'The installed CLI package differs. Remove it only after checking its contents.'
else
  staged_package=$(mktemp -d "$(dirname "$package_dir")/.install.XXXXXX")
  cp -R "$work/cli/." "$staged_package/"
  mv "$staged_package" "$package_dir"
  staged_package=
fi
ln -s "$package_dir/ai-manager" "$temporary_binary"
ln -s ai-manager "$temporary_alias"
if [ "$platform" = darwin-arm64 ]; then
  mkdir -p "$app_dir"
  staged_app=$(mktemp -d "$app_dir/.switch-install.XXXXXX")
  ditto "$work/app/Switch.app" "$staged_app/Switch.app"
  codesign --verify --deep --strict "$staged_app/Switch.app"
  if [ -e "$app_dir/Switch.app" ]; then
    previous_app="$staged_app/previous.app"
    mv "$app_dir/Switch.app" "$previous_app"
  fi
  mv "$staged_app/Switch.app" "$app_dir/Switch.app"
fi
mv -f "$temporary_binary" "$command_path"
mv -f "$temporary_alias" "$alias_path"
printf 'Installed Switch CLI %s: %s\n' "$cli_version" "$alias_path"
if [ "$platform" = darwin-arm64 ]; then
  printf 'Installed Switch %s: %s/Switch.app\n' "$app_version" "$app_dir"
fi
if [ "$(command -v switch || true)" = "$alias_path" ]; then
  printf 'Run switch to start.\n'
else
  printf 'Run %s to start. Put %s first in PATH for the switch command.\n' "$alias_path" "$bin_dir"
fi
