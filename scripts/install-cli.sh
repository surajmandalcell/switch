#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f "$1" || ! -x "$1" ]]; then
  printf '%s\n' 'Usage: install-cli.sh <ai-manager-binary> [bin-directory]' >&2
  exit 64
fi

source_binary="$1"
bin_dir="${2:-$HOME/.local/bin}"
command_path="$bin_dir/ai-manager"
alias_path="$bin_dir/switch"
if [[ -e "$alias_path" || -L "$alias_path" ]]; then
  if [[ ! -L "$alias_path" || "$(readlink "$alias_path")" != ai-manager ]]; then
    printf 'Refusing to replace an unrelated command: %s\n' "$alias_path" >&2
    exit 1
  fi
fi
if [[ -d "$command_path" ]]; then
  printf 'The command destination is a directory: %s\n' "$command_path" >&2
  exit 1
fi

mkdir -p "$bin_dir"
temporary_binary="$(mktemp "$bin_dir/.ai-manager.XXXXXX")"
temporary_alias="$temporary_binary.switch"
trap 'rm -f "$temporary_binary" "$temporary_alias"' EXIT
install -m 0755 "$source_binary" "$temporary_binary"
cmp -s "$source_binary" "$temporary_binary"
ln -s ai-manager "$temporary_alias"
mv -f "$temporary_binary" "$command_path"
mv -f "$temporary_alias" "$alias_path"
printf 'Installed %s and %s\n' "$command_path" "$alias_path"
