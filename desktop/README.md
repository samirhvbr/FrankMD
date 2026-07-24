# FrankMD Desktop

A **native desktop wrapper** for FrankMD, built with [Tauri 2](https://tauri.app).

Unlike `fed` (which opens FrankMD in a `--app` browser window), this is a real
native application: it has its own window identity, its own icon, and its own
entry in the Alt-Tab / Dock switcher. It will **not** group together with your
Brave/Chrome windows.

## Why this exists

`fed` launches the app with `brave --app=…`, so the window inherits the
browser's `WM_CLASS` and gets grouped with your normal browser windows in the
Linux window switcher. This wrapper replaces the browser with a system webview
(webkit2gtk on Linux, WKWebView on macOS) owned by a distinct application —
fixing the grouping and giving FrankMD a proper icon everywhere.

It does the same container plumbing `fed` does:

1. Ensures the `frankmd` Docker container is running for your notes directory
   (mirrors `config/fed/fed.sh`: image dir detection, env-var forwarding).
2. Waits for Rails to answer `/up`.
3. Loads the app in a native window.

## Prerequisites

- **Docker** (running) — the app boots the `frankmd` container.
- **Rust** (stable) — <https://rustup.rs>
- **Tauri CLI** — `cargo install tauri-cli --version '^2'` *or* use the npm
  wrapper (`npm install` here, then `npm run …`).
- **Linux system deps** (Debian/Ubuntu example):
  ```bash
  sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget file \
    libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev
  ```
  (On Arch/Omarchy: `webkit2gtk-4.1 base-devel curl wget file openssl gtk3 libayatana-appindicator librsvg`.)
- **macOS**: Xcode Command Line Tools (`xcode-select --install`).

## Develop

```bash
cd desktop
cargo tauri dev      # or: npm install && npm run dev
```

## Build installable bundles

```bash
cd desktop
cargo tauri build    # or: npm run build
```

Artifacts land in `src-tauri/target/release/bundle/`:

- **Linux**: `.deb` and `.AppImage`
- **macOS**: `.app` and `.dmg`

## Usage

The app opens a notes directory the same way `fed` does. Resolution order:

1. First CLI argument — `FrankMD /path/to/notes`
2. `$FRANKMD_NOTES`
3. Current working directory

Environment overrides:

| Var | Default | Purpose |
|-----|---------|---------|
| `FRANKMD_IMAGE` | `akitaonrails/frankmd:latest` | Container image to run |
| `FRANKMD_PORT` | `7591` | Host port mapped to the container |
| `FRANKMD_NOTES` | — | Notes dir when no CLI arg is given |
| `IMAGES_PATH` | auto | Images dir mounted read-only at `/data/images` |

AWS / AI / YouTube / Google keys present in the environment are forwarded into
the container, exactly like `fed` (the notes-folder `.fed` file still wins).

## Regenerating icons

Icons under `src-tauri/icons/` are generated from the project's master icon:

```bash
cargo tauri icon ../public/icon.svg -o src-tauri/icons
```

## Notes for maintainers

- `FRANKMD_IMAGE` defaults to the **upstream** image (`akitaonrails/frankmd`).
  Once this fork publishes its own image, change `DEFAULT_IMAGE` in
  `src-tauri/src/main.rs` (and this table) to point at it.
- The app has no custom IPC surface: the loaded FrankMD page is plain web
  content in the webview and cannot call Tauri commands (capabilities grant
  only `core:default`).
- If Linux Alt-Tab still groups the window incorrectly on your compositor, the
  window's app id derives from the `identifier` in `tauri.conf.json`
  (`com.frankmd.desktop`); ensure the generated `.desktop` file's
  `StartupWMClass` matches it (Tauri sets this in the bundle).
