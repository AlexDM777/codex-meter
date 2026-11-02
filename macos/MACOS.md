# CodexMeter for macOS

Requires macOS 13 or later. The Universal app supports Apple Silicon and Intel. It uses your installed Codex; neither Codex nor a browser is bundled.

## Install and sign in

1. Download the macOS DMG from [Releases](https://github.com/AlexDM777/codex-meter/releases/latest). Open it and drag CodexMeter into Applications. Alternatively, extract the Universal ZIP into Applications or ~/Applications.
2. Install the official Codex app or Codex CLI if you do not already have it. CodexMeter detects Codex.app through macOS and checks common Homebrew, npm, nvm and PATH locations automatically.
3. Open CodexMeter settings and click **Sign in to ChatGPT**. Your default browser opens the authorization page. Complete sign-in there and return to the widget.

If Codex was installed while the widget was open, expand **Codex connection** and click **Find Codex**. For a custom installation, use **Choose Codex.app** and select the app itself or the `codex` executable. Connection errors appear in settings. While sign-in is pending, you can reopen the browser or copy the sign-in link.

The app has an ad-hoc integrity signature, without Apple Developer ID or notarization. macOS may restrict its first launch. Do not disable Gatekeeper. You can build the app from source using the commands below.

## Controls

- Drag the widget to move it; scroll to resize from 100 to 1000.
- Double-click the widget to expand to 800 and restore its previous size.
- Double-click its menu bar indicator to expand a small widget or hide an expanded one.
- Hover over the menu bar indicator for the quota card; right-click for the menu.
- Settings contain skin previews, live preview, eight languages, random skins, custom skin import, sign-in and updates.
- On first launch the app uses your system language if supported, otherwise English. A manual language selection is saved.
- Copy a widget screenshot without screen recording permission.

Settings, the separate widget account and custom skins are stored in `~/Library/Application Support/CodexMeter`. The widget does not copy your primary Codex auth.json. Use [SkinGuide.md](../SkinGuide.md) to create a custom theme; import `skin.json` with its background next to it.

## Build and test on a Mac

Install Xcode Command Line Tools, then run from the repository root:

```sh
bash macos/build.sh
build/macos/CodexMeter.app/Contents/MacOS/CodexMeter --self-test
build/macos/CodexMeter.app/Contents/MacOS/CodexMeter --rpc-test /absolute/path/to/codex
```

The RPC regression test uses a temporary profile. It initializes the real Codex app-server, requests a browser sign-in URL, cancels authorization, and reconnects. It does not sign in to a personal account. GitHub Actions builds both architectures and runs native tests on Apple Silicon and Intel. Completing authorization and reading live limits still require a real user account.
