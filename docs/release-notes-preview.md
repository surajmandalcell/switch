This is an **unnotarized preview** of the native Switch app for macOS 14 or later on Apple Silicon. It is ad hoc signed, so macOS will not identify it as a verified developer download.

1. Download the ZIP and checksum file from this release. Check the ZIP with `shasum -a 256 -c checksums-v3.0.0-preview.1.txt` in the download folder.
2. Unzip it and move `Switch.app` to Applications.
3. Try to open Switch. If macOS blocks it, open **System Settings → Privacy & Security** and select **Open Anyway**, then confirm **Open**. [Apple explains this exception](https://support.apple.com/en-gb/102445).

Do not disable Gatekeeper or remove the download's quarantine attribute. If macOS says the app is damaged or contains malware, stop and report it. Codex CLI is required for live sign-in, usage checks, and launching Codex.
