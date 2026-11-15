# Sidecar Toggle

A tiny menu bar app that connects or disconnects your iPad as a Sidecar display, with a keyboard shortcut you choose.

- Lives in the menu bar; no Dock icon (it shows in the Dock only while Settings is open)
- **Open at login** toggle
- **Show in menu bar** toggle. With the icon hidden, open the app from Applications or Spotlight to get to Settings
- Custom toggle shortcut (default ⌃⌥⌘S)
- Follows macOS Light/Dark
- macOS 13 or later, Apple Silicon and Intel

## Install

1. **[Download SidecarToggle.dmg](https://github.com/oxybundy/sidecar-toggle/releases/latest/download/SidecarToggle.dmg)**
2. Open it and drag **Sidecar Toggle** onto the **Applications** folder next to it.
3. Eject the disk image and open Sidecar Toggle from Applications or Spotlight.

If you open it straight from the disk image by mistake, it offers to move itself into Applications.

### "Apple could not verify…" the first time

The app isn't notarized by Apple, so macOS blocks the first launch:

- **macOS 15 (Sequoia) and later:** try to open it once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
- **macOS 13–14:** right-click the app → **Open** → **Open**.

Or clear the download flag in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Sidecar Toggle.app"
```

## Build from source

Needs the Xcode command-line tools (`xcode-select --install`).

```sh
./build.sh          # build/Sidecar Toggle.app
./build.sh dmg      # build/SidecarToggle.dmg
./build.sh install  # build and copy into /Applications
```

Every push to `main` builds the DMG on GitHub Actions and publishes it as a release tagged with the version in `Resources/Info.plist` (re-pushing the same version replaces the DMG). For a new release, bump `CFBundleShortVersionString` and add a matching section to `CHANGELOG.md`; that section becomes the release notes.

## Notes

- Uses Apple's private `SidecarCore` framework, so a macOS update could break it.
- Several iPads? Pick one by name: `defaults write com.oxybundy.SidecarToggle deviceName "iPad Pro"`
- `design/AppIcon.svg` is the icon source; `Resources/AppIcon.iconset` is rendered from it.
