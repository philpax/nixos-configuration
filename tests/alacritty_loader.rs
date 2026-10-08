// Compiled only as a child of Alacritty v0.17.0's config module in the test derivation.
use super::{read_config, Action, BindingKey, UiConfig};
use log::{Level, LevelFilter, Log, Metadata, Record};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use winit::keyboard::{Key, ModifiersState, NamedKey};

struct Diagnostics(Mutex<Vec<String>>);
static DIAGNOSTICS: Diagnostics = Diagnostics(Mutex::new(Vec::new()));

impl Log for Diagnostics {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.level() <= Level::Warn
    }

    fn log(&self, record: &Record<'_>) {
        if self.enabled(record.metadata()) {
            self.0.lock().unwrap().push(format!("{}: {}", record.level(), record.args()));
        }
    }

    fn flush(&self) {}
}

fn load_clean(main: &Path) -> UiConfig {
    DIAGNOSTICS.0.lock().unwrap().clear();
    let config = read_config(main).expect("deployed main config must load without fallback");
    assert!(DIAGNOSTICS.0.lock().unwrap().is_empty(), "loader diagnostics: {:?}",
        DIAGNOSTICS.0.lock().unwrap());
    config
}

fn assert_shared(config: &UiConfig) {
    assert_eq!(config.font.normal().family, "Cozette");
    assert_eq!(config.font.normal().style.as_deref(), Some("Regular"));
    for (mods, action) in [
        (ModifiersState::CONTROL | ModifiersState::SHIFT, Action::SpawnNewInstance),
        (ModifiersState::SHIFT, Action::Esc("\n".into())),
    ] {
        assert!(config.key_bindings().iter().any(|binding| {
            matches!(&binding.trigger, BindingKey::Keycode { key: Key::Named(NamedKey::Enter), .. })
                && binding.mods == mods && binding.action == action
        }), "shared Return binding absent: {mods:?} / {action:?}");
    }
}

#[test]
fn alacritty_deployed_config_loader() {
    log::set_logger(&DIAGNOSTICS).expect("test logger must be exclusive");
    log::set_max_level(LevelFilter::Warn);
    let root = PathBuf::from(env::var_os("FRAME_TERMINAL_FIXTURE").expect("fixture is required"));
    let manifest: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("manifest.json")).unwrap()).unwrap();
    let path = |key: &str| PathBuf::from(manifest[key].as_str().unwrap());
    let main = path("main");
    let import = path("import");
    let wrapper = manifest["wrapper"].as_str().unwrap();
    let args: Vec<String> = manifest["args"].as_array().unwrap().iter()
        .map(|value| value.as_str().unwrap().to_owned()).collect();
    assert_eq!(PathBuf::from(env::var_os("HOME").unwrap()), path("home"));
    assert!(main.is_symlink(), "main must be a deployed symlink");
    assert!(main.to_string_lossy().contains(" "));
    assert!(main.canonicalize().unwrap().to_string_lossy().contains("checkout with spaces"));
    assert!(path("bell").is_file());
    assert!(!fs::read(path("bell")).unwrap().is_empty());
    let imported = fs::read_to_string(&import).unwrap();

    // Optional missing import retains the default shell and all main-file fields.
    fs::remove_file(&import).unwrap();
    let config = load_clean(&main);
    assert!(config.terminal.shell.is_none());
    assert!(config.pty_config().shell.is_none());
    assert_shared(&config);
    // Upstream records an attempted missing import before reading it.
    assert_eq!(config.config_paths, vec![main.clone(), import.clone()]);

    fs::write(&import, &imported).unwrap();
    let config = load_clean(&main);
    let shell = config.terminal.shell.as_ref().expect("Frame shell import not loaded");
    assert_eq!(shell.program(), wrapper);
    assert_eq!(shell.args(), args.as_slice());
    assert!(config.pty_config().shell.is_some());
    assert_shared(&config);
    assert_eq!(config.config_paths, vec![main.clone(), import.clone()]);

    // Main fields win over imports. A relative recursive import is resolved from
    // the deployed import directory, never the main symlink's checkout target.
    let nested = import.parent().unwrap().join("nested import with spaces.toml");
    fs::write(&nested, "[env]\nFRAME_LOADER_NESTED = 'resolved'\n").unwrap();
    fs::write(&import, format!("{imported}\n[general]\nimport = ['nested import with spaces.toml']\n\
        [font.normal]\nfamily = 'Wrong Imported Family'\nstyle = 'Wrong'\n\
        [window]\nopacity = 0.2\n")).unwrap();
    let config = load_clean(&main);
    assert_shared(&config);
    assert_eq!(config.window_opacity(), 0.8);
    assert_eq!(config.env.get("FRAME_LOADER_NESTED").map(String::as_str), Some("resolved"));
    assert_eq!(config.config_paths, vec![main.clone(), import.clone(), nested]);
    assert_eq!(config.terminal.shell.as_ref().unwrap().program(), wrapper);

    let main_bytes = fs::read_to_string(&main).unwrap();
    fs::write(&main, format!("{main_bytes}\n[terminal.shell]\nprogram = '/bin/sh'\nargs = ['main-sentinel']\n")).unwrap();
    let config = load_clean(&main);
    assert_eq!(config.terminal.shell.as_ref().unwrap().program(), "/bin/sh");
    // Upstream merges arrays by concatenation, even when the main program wins.
    let mut merged_args = args.clone();
    merged_args.push("main-sentinel".into());
    assert_eq!(config.terminal.shell.as_ref().unwrap().args(), merged_args.as_slice());
    assert_shared(&config);
    fs::write(&main, main_bytes).unwrap();

    // Invalid imported TOML and bindings can otherwise fall back silently.
    for bad in ["[terminal.shell", "[[keyboard.bindings]]\nkey = 'Return'\naction = 'BadAction'\n"] {
        fs::write(&import, bad).unwrap();
        DIAGNOSTICS.0.lock().unwrap().clear();
        let _ = read_config(&main);
        assert!(!DIAGNOSTICS.0.lock().unwrap().is_empty(),
            "negative fixture must exercise loader diagnostic capture");
    }
    fs::write(&import, imported).unwrap();
    assert_shared(&load_clean(&main));
}
