// Prevent an extra console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! FrankMD native desktop wrapper.
//!
//! Responsibilities (mirrors the `fed` shell function in `config/fed/fed.sh`,
//! but as a native app with its own window identity):
//!   1. Resolve which notes directory to open.
//!   2. Ensure the `frankmd` Docker container is running for it.
//!   3. Wait for Rails to answer `/up`, then navigate the webview to the app.
//!
//! Notes directory resolution (first hit wins):
//!   CLI arg 1  ->  $FRANKMD_NOTES  ->  last remembered dir (if it still exists)
//!   ->  native folder picker.  A valid choice is remembered for next launch.
//!   If the picker is cancelled, the app shows a message and does not boot.
//!
//! Overridable via env: FRANKMD_IMAGE, FRANKMD_PORT, IMAGES_PATH.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager, Url};
use tauri_plugin_dialog::DialogExt;

const CONTAINER: &str = "frankmd";
const DEFAULT_IMAGE: &str = "akitaonrails/frankmd:latest";
const DEFAULT_PORT: &str = "7591";
const BOOT_TIMEOUT: Duration = Duration::from_secs(90);
const LAST_DIR_FILE: &str = "last-notes-dir";

/// Host env vars forwarded into the container (the `.fed` file still overrides
/// these at runtime). Kept in sync with `config/fed/fed.sh`.
const FORWARD_ENV: &[&str] = &[
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_S3_BUCKET",
    "AWS_REGION",
    "YOUTUBE_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_CSE_ID",
    "AI_PROVIDER",
    "AI_MODEL",
    "OLLAMA_API_BASE",
    "OLLAMA_MODEL",
    "OPENROUTER_API_KEY",
    "OPENROUTER_MODEL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "GEMINI_API_KEY",
    "GEMINI_MODEL",
    "OPENAI_API_KEY",
    "OPENAI_MODEL",
    "IMAGE_GENERATION_MODEL",
    "FRANKMD_LOCALE",
];

fn port() -> String {
    std::env::var("FRANKMD_PORT").unwrap_or_else(|_| DEFAULT_PORT.to_string())
}

fn image() -> String {
    std::env::var("FRANKMD_IMAGE").unwrap_or_else(|_| DEFAULT_IMAGE.to_string())
}

fn app_url() -> String {
    format!("http://localhost:{}", port())
}

fn health_url() -> String {
    format!("http://localhost:{}/up", port())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let handle = app.handle().clone();
            // Boot the backend off the UI thread; the splash is already visible.
            thread::spawn(move || boot(handle));
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the FrankMD desktop app");
}

fn boot(handle: AppHandle) {
    let notes = match resolve_notes_dir(&handle) {
        Some(dir) => dir,
        None => {
            show_error(
                &handle,
                "No notes folder selected.\n\nClose and reopen FrankMD to choose one.",
            );
            return;
        }
    };

    set_status(&handle, "Starting FrankMD…");

    if let Err(err) = ensure_container(&notes) {
        show_error(&handle, &format!("Could not start the FrankMD container.\n\n{err}"));
        return;
    }
    if wait_for_health(BOOT_TIMEOUT) {
        navigate_to_app(&handle);
    } else {
        show_error(
            &handle,
            "Timed out waiting for FrankMD to start.\n\nIs Docker running? Try `docker logs frankmd`.",
        );
    }
}

// --- Notes directory resolution ------------------------------------------------

/// CLI arg -> $FRANKMD_NOTES -> remembered dir -> folder picker. Remembers valid choices.
fn resolve_notes_dir(handle: &AppHandle) -> Option<PathBuf> {
    if let Some(arg) = std::env::args().nth(1) {
        let p = canonical_or(PathBuf::from(arg));
        if p.is_dir() {
            remember_dir(handle, &p);
            return Some(p);
        }
    }

    if let Ok(env) = std::env::var("FRANKMD_NOTES") {
        if !env.is_empty() {
            let p = canonical_or(PathBuf::from(env));
            if p.is_dir() {
                remember_dir(handle, &p);
                return Some(p);
            }
        }
    }

    // Last remembered directory — only if it still exists (it may have been
    // moved or deleted since last time).
    if let Some(last) = load_remembered_dir(handle) {
        if last.is_dir() {
            return Some(last);
        }
    }

    // Nothing usable: ask the user to pick a folder.
    set_status(handle, "Choose your notes folder…");
    if let Some(picked) = pick_folder(handle) {
        remember_dir(handle, &picked);
        return Some(picked);
    }

    None
}

fn pick_folder(handle: &AppHandle) -> Option<PathBuf> {
    handle
        .dialog()
        .file()
        .set_title("Select your FrankMD notes folder")
        .blocking_pick_folder()
        .and_then(|fp| fp.into_path().ok())
}

fn remembered_dir_path(handle: &AppHandle) -> Option<PathBuf> {
    let config_dir = handle.path().app_config_dir().ok()?;
    Some(config_dir.join(LAST_DIR_FILE))
}

fn load_remembered_dir(handle: &AppHandle) -> Option<PathBuf> {
    let file = remembered_dir_path(handle)?;
    let content = std::fs::read_to_string(file).ok()?;
    let trimmed = content.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(PathBuf::from(trimmed))
    }
}

fn remember_dir(handle: &AppHandle, path: &Path) {
    if let Some(file) = remembered_dir_path(handle) {
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(file, path.to_string_lossy().as_bytes());
    }
}

fn canonical_or(p: PathBuf) -> PathBuf {
    std::fs::canonicalize(&p).unwrap_or(p)
}

// --- Container orchestration ---------------------------------------------------

/// Ensure a `frankmd` container is running with `notes` mounted at /rails/notes.
/// If one is running with a different notes mount, it is stopped and replaced.
fn ensure_container(notes: &Path) -> Result<(), String> {
    let notes_str = notes.to_string_lossy().to_string();

    if container_running() {
        match current_notes_mount() {
            Some(current) if current == notes_str => return Ok(()), // already serving this dir
            _ => {
                let _ = docker(&["stop", CONTAINER]);
            }
        }
    }

    // `--rm` containers may linger in "created"/"exited" briefly; ignore errors.
    let _ = docker(&["rm", CONTAINER]);

    let port_map = format!("{}:80", port());
    let user = format!("{}:{}", id_flag("-u"), id_flag("-g"));
    let notes_vol = format!("{notes_str}:/rails/notes");

    let mut args: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        "--name".into(),
        CONTAINER.into(),
        "--rm".into(),
        "-p".into(),
        port_map,
        "--user".into(),
        user,
        "-v".into(),
        notes_vol,
    ];

    if let Some(images_dir) = detect_images_dir(notes) {
        args.push("--mount".into());
        args.push(format!(
            "type=bind,source={},target=/data/images,readonly",
            images_dir.to_string_lossy()
        ));
        args.push("-e".into());
        args.push("IMAGES_PATH=/data/images".into());
    }

    for var in FORWARD_ENV {
        if let Ok(val) = std::env::var(var) {
            if !val.is_empty() {
                args.push("-e".into());
                args.push(format!("{var}={val}"));
            }
        }
    }

    args.push(image());

    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = docker(&arg_refs)?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(())
}

fn container_running() -> bool {
    docker(&["ps", "-q", "-f", "name=frankmd"])
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false)
}

fn current_notes_mount() -> Option<String> {
    let out = docker(&[
        "inspect",
        CONTAINER,
        "--format",
        "{{range .Mounts}}{{if eq .Destination \"/rails/notes\"}}{{.Source}}{{end}}{{end}}",
    ])
    .ok()?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// IMAGES_PATH env > `images_path` in <notes>/.fed > $XDG_PICTURES_DIR > ~/Pictures.
fn detect_images_dir(notes: &Path) -> Option<PathBuf> {
    if let Ok(p) = std::env::var("IMAGES_PATH") {
        if !p.is_empty() {
            return existing_dir(PathBuf::from(p));
        }
    }
    if let Some(p) = images_path_from_fed(notes) {
        if let Some(dir) = existing_dir(p) {
            return Some(dir);
        }
    }
    if let Ok(p) = std::env::var("XDG_PICTURES_DIR") {
        if !p.is_empty() {
            if let Some(dir) = existing_dir(PathBuf::from(p)) {
                return Some(dir);
            }
        }
    }
    existing_dir(home_dir()?.join("Pictures"))
}

fn images_path_from_fed(notes: &Path) -> Option<PathBuf> {
    let content = std::fs::read_to_string(notes.join(".fed")).ok()?;
    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("images_path") {
            let val = rest.trim_start().strip_prefix('=')?.trim();
            let val = val.trim_matches(|c| c == '"' || c == '\'').trim();
            if val.is_empty() {
                return None;
            }
            let expanded = if let Some(sub) = val.strip_prefix("~/") {
                home_dir()?.join(sub)
            } else {
                PathBuf::from(val)
            };
            return Some(expanded);
        }
    }
    None
}

fn existing_dir(p: PathBuf) -> Option<PathBuf> {
    let p = std::fs::canonicalize(&p).unwrap_or(p);
    if p.is_dir() {
        Some(p)
    } else {
        None
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// `id -u` / `id -g`, defaulting to 1000 when unavailable (e.g. non-Unix dev).
fn id_flag(flag: &str) -> String {
    Command::new("id")
        .arg(flag)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "1000".to_string())
}

fn docker(args: &[&str]) -> Result<std::process::Output, String> {
    Command::new("docker")
        .args(args)
        .output()
        .map_err(|e| format!("failed to run `docker` (is it installed and on PATH?): {e}"))
}

// --- Health + navigation -------------------------------------------------------

fn wait_for_health(timeout: Duration) -> bool {
    let url = health_url();
    let start = Instant::now();
    while start.elapsed() < timeout {
        let ok = ureq::get(&url)
            .timeout(Duration::from_secs(2))
            .call()
            .map(|r| r.status() == 200)
            .unwrap_or(false);
        if ok {
            return true;
        }
        thread::sleep(Duration::from_millis(300));
    }
    false
}

fn navigate_to_app(handle: &AppHandle) {
    if let Some(win) = handle.get_webview_window("main") {
        if let Ok(url) = Url::parse(&app_url()) {
            let _ = win.navigate(url);
        }
    }
}

fn set_status(handle: &AppHandle, text: &str) {
    if let Some(win) = handle.get_webview_window("main") {
        let safe = js_escape(text);
        let _ = win.eval(&format!(
            "var s=document.querySelector('.status'); if(s){{s.textContent='{safe}';}}"
        ));
    }
}

fn show_error(handle: &AppHandle, message: &str) {
    if let Some(win) = handle.get_webview_window("main") {
        let safe = js_escape(message);
        let _ = win.eval(&format!(
            "window.frankmdError && window.frankmdError('{safe}');"
        ));
    }
}

fn js_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('\'', "\\'")
        .replace('\n', "\\n")
}
