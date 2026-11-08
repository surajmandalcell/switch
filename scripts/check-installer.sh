#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${AGENT_DATA_DIR:-${TMPDIR:-/tmp}}/switch-installer-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/mock" "$work/assets" "$work/cli" "$work/app/Switch.app/Contents"
cat > "$work/cli/ai-manager" <<'SH'
#!/bin/sh
echo "Switch ${FIXTURE_VERSION:-3.9.1}"
SH
chmod +x "$work/cli/ai-manager"
printf 'license\n' > "$work/cli/SWIFT-LICENSE.txt"
for platform in darwin-arm64 linux-x86_64 linux-aarch64; do
  printf 'bundled runtime %s\n' "$platform" > "$work/cli/libswiftCore.so"
  tar -czf "$work/assets/Switch-cli-v3.9.1-$platform.tar.gz" -C "$work/cli" ai-manager libswiftCore.so SWIFT-LICENSE.txt
done
printf 'fixture app\n' > "$work/app/Switch.app/Contents/Info.plist"
(cd "$work/app" && zip -qr "$work/assets/Switch-v3.8.2-mac-arm64.zip" Switch.app)
(cd "$work/assets" && shasum -a 256 Switch-cli-*.tar.gz > checksums.txt && shasum -a 256 Switch-v3.8.2-mac-arm64.zip > checksums-v3.8.2.txt)
cat > "$work/mock/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in https://*) url="$1";; -o) shift; output="$1";; esac
  shift
done
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
cp "$ASSETS/${url##*/}" "$output"
if [ "${BAD_CHECKSUM:-0}" = 1 ]; then
  case "$url" in *.tar.gz) printf 'bad' >> "$output";; esac
fi
SH
cat > "$work/mock/uname" <<'SH'
#!/bin/sh
case "$1" in -s) echo "$OS";; -m) echo "$ARCH";; esac
SH
cat > "$work/mock/getconf" <<'SH'
#!/bin/sh
[ "${FAIL_GETCONF:-0}" = 0 ] || exit 1
echo "glibc ${GLIBC:-2.39}"
SH
cat > "$work/mock/sw_vers" <<'SH'
#!/bin/sh
echo 14.0
SH
cat > "$work/mock/ps" <<'SH'
#!/bin/sh
if [ "${APP_RUNNING:-0}" = 1 ]; then
  echo "$HOME/Applications/Switch.app/Contents/MacOS/AIManager"
fi
SH
cat > "$work/mock/codesign" <<'SH'
#!/bin/sh
[ "${BAD_SIGNATURE:-0}" = 0 ] || exit 1
echo 'anchor apple generic and certificate leaf[subject.OU] = "GF57JXJF5A"' >&2
SH
cat > "$work/mock/spctl" <<'SH'
#!/bin/sh
[ "${BAD_SIGNATURE:-0}" = 0 ]
SH
cat > "$work/mock/ditto" <<'SH'
#!/bin/sh
if [ "$1" = -x ]; then
  mkdir -p "$4"
  unzip -q "$3" -d "$4"
else
  mkdir -p "$2"
  cp -R "$1/." "$2/"
fi
SH
chmod +x "$work/mock/"*
export PATH="$work/mock:$PATH" ASSETS="$work/assets"
unset XDG_DATA_HOME
export HOME="$work/home" OS=Linux ARCH=x86_64
mkdir -p "$HOME"
run() { sh "$root/install.sh" > "$work/output" 2>&1; }
reject() { if run; then printf 'Unexpected installer success\n' >&2; exit 1; fi; }

run
test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
test "$(cat "$HOME/.local/share/switch/cli/3.9.1/libswiftCore.so")" = 'bundled runtime linux-x86_64'
export GLIBC=2.38
run
unset GLIBC
printf '#!/bin/sh\necho stale\n' > "$work/mock/switch"
chmod +x "$work/mock/switch"
export PATH="$PATH:$HOME/.local/bin"
run
grep -F "Put $HOME/.local/bin first in PATH" "$work/output" >/dev/null
rm "$work/mock/switch"
printf 'keep\n' > "$HOME/.local/bin/unrelated"
export BAD_CHECKSUM=1
reject
test "$(cat "$HOME/.local/bin/unrelated")" = keep
test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
unset BAD_CHECKSUM
export FIXTURE_VERSION=0.0.0
reject
unset FIXTURE_VERSION
export GLIBC=2.37
reject
unset GLIBC
export GLIBC=invalid
reject
unset GLIBC
export FAIL_GETCONF=1
reject
unset FAIL_GETCONF
export ARCH=riscv64
reject
export ARCH=x86_64
export FAIL_DOWNLOAD=1
reject
unset FAIL_DOWNLOAD
rm "$HOME/.local/bin/switch"
printf 'unrelated\n' > "$HOME/.local/bin/switch"
reject
test "$(cat "$HOME/.local/bin/switch")" = unrelated
export HOME="$work/fresh-failure" BAD_CHECKSUM=1
mkdir -p "$HOME"
reject
test ! -e "$HOME/.local"
unset BAD_CHECKSUM

for arch in aarch64 arm64; do
  export HOME="$work/linux-$arch-home" OS=Linux ARCH="$arch"
  export GLIBC=2.38
  mkdir -p "$HOME"
  run
  test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
  test "$(cat "$HOME/.local/share/switch/cli/3.9.1/libswiftCore.so")" = 'bundled runtime linux-aarch64'
  run
  export BAD_CHECKSUM=1
  reject
  unset BAD_CHECKSUM
  export FIXTURE_VERSION=0.0.0
  reject
  unset FIXTURE_VERSION
  export GLIBC=2.37
  reject
  unset GLIBC
  export GLIBC=invalid
  reject
  unset GLIBC
  export FAIL_GETCONF=1
  reject
  unset FAIL_GETCONF
  test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
done

export HOME="$work/mac-home" OS=Darwin ARCH=arm64
mkdir -p "$HOME"
run
test -f "$HOME/Applications/Switch.app/Contents/Info.plist"
test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
run
export APP_RUNNING=1
reject
unset APP_RUNNING
export BAD_SIGNATURE=1
reject
unset BAD_SIGNATURE
test "$(cat "$HOME/Applications/Switch.app/Contents/Info.plist")" = 'fixture app'
test "$("$HOME/.local/bin/switch" --version)" = 'Switch 3.9.1'
printf 'INSTALLER_FIXTURES_PASS: Linux x86_64/aarch64/arm64 and Mac install, repeat, checksum, wrong version, old/invalid glibc, unsupported architecture, download, unrelated command, running app, signature\n'
