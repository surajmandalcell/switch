#!/usr/bin/env bash

set -euo pipefail

fail() { printf 'RELEASE_NOT_READY: %s\n' "$1" >&2; exit 1; }

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "pass a new version such as v3.0.0"
[[ "$(uname -s)" == Darwin ]] || fail "run this on a Mac"
[[ "${AI_MANAGER_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || \
  fail "set AI_MANAGER_SIGNING_IDENTITY to a Developer ID Application identity"
security find-identity -v -p codesigning | grep -F "\"$AI_MANAGER_SIGNING_IDENTITY\"" >/dev/null || \
  fail "the Developer ID Application identity is not available on this Mac"
[[ "${AI_MANAGER_NOTARY_KEY_PATH:-}" == /* ]] || fail "use an absolute AI_MANAGER_NOTARY_KEY_PATH"
[[ -r "${AI_MANAGER_NOTARY_KEY_PATH:-}" ]] || fail "set AI_MANAGER_NOTARY_KEY_PATH to a readable .p8 key"
[[ -n "${AI_MANAGER_NOTARY_KEY_ID:-}" ]] || fail "set AI_MANAGER_NOTARY_KEY_ID"
command -v gh >/dev/null || fail "install GitHub CLI"
command -v jq >/dev/null || fail "install jq"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
[[ "$build_path" == /* ]] || fail "AI_MANAGER_BUILD_PATH must be absolute"
release_dir="$repo_root/release"
app_path="$build_path/package/Switch.app"
cli_path="$build_path/artifacts/ai-manager"
submission="$build_path/release-submission.zip"
archive="$release_dir/Switch-$tag-mac-arm64.zip"
checksum="$release_dir/checksums-$tag.txt"
version="${tag#v}"

[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || fail "commit all source changes first"
head="$(git -C "$repo_root" rev-parse HEAD)"
upstream="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" || \
  fail "set an upstream branch"
remote="${upstream%%/*}"
branch="${upstream#*/}"
remote_head="$(git -C "$repo_root" ls-remote "$remote" "refs/heads/$branch" | awk 'NR == 1 { print $1 }')"
[[ "$remote_head" == "$head" ]] || fail "push the committed source before releasing"

if git -C "$repo_root" show-ref --verify --quiet "refs/tags/$tag"; then
  [[ "$(git -C "$repo_root" rev-list -n 1 "$tag")" == "$head" ]] || fail "$tag points to another commit"
else
  latest="$(git -C "$repo_root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | sed -n '1p')"
  [[ -z "$latest" || "$(printf '%s\n%s\n' "$latest" "$tag" | sort -V | tail -n 1)" == "$tag" ]] || \
    fail "choose a version newer than $latest"
fi
remote_tag="$(git -C "$repo_root" ls-remote --tags "$remote" "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')"
if [[ -z "$remote_tag" ]]; then
  remote_tag="$(git -C "$repo_root" ls-remote --tags "$remote" "refs/tags/$tag" | awk 'NR == 1 { print $1 }')"
fi
[[ -z "$remote_tag" || "$remote_tag" == "$head" ]] || fail "remote $tag points to another commit"

gh auth status >/dev/null 2>&1 || fail "sign in with GitHub CLI"
repo="$(cd "$repo_root" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  fail "$tag already has a GitHub release"
fi

cd "$repo_root"
scripts/check-native.sh
AI_MANAGER_VERSION="$version" scripts/build-native.sh
bash packages/tui/Tests/acceptance.sh "$cli_path"

notary_args=(--key "$AI_MANAGER_NOTARY_KEY_PATH" --key-id "$AI_MANAGER_NOTARY_KEY_ID")
if [[ -n "${AI_MANAGER_NOTARY_ISSUER_ID:-}" ]]; then
  notary_args+=(--issuer "$AI_MANAGER_NOTARY_ISSUER_ID")
fi
rm -f "$submission"
payload_dir="$(mktemp -d "$build_path/release-payload.XXXXXX")"
trap 'rm -r "$payload_dir"' EXIT
ditto "$app_path" "$payload_dir/Switch.app"
install -m 0755 "$cli_path" "$payload_dir/ai-manager"
ditto -c -k --sequesterRsrc --keepParent "$payload_dir" "$submission"
notary_result="$(xcrun notarytool submit "$submission" "${notary_args[@]}" --wait --output-format json)"
printf '%s\n' "$notary_result" | jq -e '.status == "Accepted"' >/dev/null || fail "Apple rejected notarization"
xcrun stapler staple "$app_path"
scripts/check-release-readiness.sh --public "$app_path" "$cli_path"

mkdir -p "$release_dir"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
(cd "$release_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")")
(cd "$release_dir" && shasum -a 256 -c "$(basename "$checksum")")

verify_dir="$(mktemp -d "$build_path/release-verify.XXXXXX")"
trap 'rm -r "$payload_dir" "$verify_dir"' EXIT
ditto -x -k "$archive" "$verify_dir"
scripts/check-release-readiness.sh --public "$verify_dir/Switch.app" "$cli_path"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$verify_dir/Switch.app/Contents/Info.plist")" == "$version" ]] || \
  fail "archived app version does not match $tag"

if ! git show-ref --verify --quiet "refs/tags/$tag"; then
  git tag -a "$tag" -m "Switch $version"
fi
if [[ -z "$remote_tag" ]]; then
  git push "$remote" "$tag"
fi
gh release create "$tag" "$archive" "$checksum" --repo "$repo" --verify-tag \
  --title "Switch $version" --draft \
  --notes "Native Switch for macOS 14 or later on Apple Silicon. Download the ZIP, unzip it, and move Switch.app to Applications. Codex CLI is required for live sign-in, usage checks, and launching Codex."

mkdir -p "$verify_dir/download"
gh release download "$tag" --repo "$repo" --dir "$verify_dir/download"
cmp "$archive" "$verify_dir/download/$(basename "$archive")" || fail "uploaded archive differs from the local package"
cmp "$checksum" "$verify_dir/download/$(basename "$checksum")" || fail "uploaded checksum differs from the local file"
gh release edit "$tag" --repo "$repo" --draft=false --latest

for old in "$release_dir"/Switch-v*-mac-arm64.zip "$release_dir"/checksums-v*.txt; do
  [[ -f "$old" && "$old" != "$archive" && "$old" != "$checksum" ]] || continue
  printf 'Removing superseded release artifact: %s\n' "$old"
  rm "$old"
done
printf 'Published %s\nArchive: %s\nChecksum: %s\n' \
  "$(gh release view "$tag" --repo "$repo" --json url --jq .url)" "$archive" "$checksum"
