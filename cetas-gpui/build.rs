use serde::Deserialize;
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Debug, Deserialize)]
struct CapturedSource {
    original: String,
    copied: String,
}

#[derive(Debug, Deserialize)]
struct FinalLink {
    expanded_argv: Vec<String>,
    sources: Vec<CapturedSource>,
    output: Option<String>,
}

fn moon_home() -> PathBuf {
    if let Ok(value) = env::var("MOON_HOME") {
        return PathBuf::from(value);
    }
    let output = Command::new("sh")
        .args(["-lc", "command -v moon"])
        .output()
        .expect("failed to locate moon");
    assert!(output.status.success(), "moon is not installed or not on PATH");
    let moon = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
    moon.parent()
        .and_then(Path::parent)
        .expect("unexpected moon executable path")
        .to_path_buf()
}

fn same_source(arg: &str, source: &str) -> bool {
    if arg == source {
        return true;
    }
    Path::new(arg)
        .canonicalize()
        .ok()
        .zip(Path::new(source).canonicalize().ok())
        .map(|(a, b)| a == b)
        .unwrap_or(false)
}

fn main() {
    let target = env::var("TARGET").expect("TARGET");
    if target != "aarch64-apple-darwin" {
        panic!("cetas-gpui POC supports only aarch64-apple-darwin (got {target})");
    }

    println!("cargo:rerun-if-changed=moon");
    println!("cargo:rerun-if-changed=tools/moon_cc_capture.py");

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let moon_dir = manifest_dir.join("moon");
    let repo_root = manifest_dir.parent().expect("cetas-gpui must live in the Cetas repository");
    let recipe_status = Command::new("python3")
        .args(["scripts/prepare-recipe.py", "--flavor", "public", "--frontend", "all", "--platform", "unix"])
        .current_dir(repo_root)
        .status()
        .expect("failed to prepare Cetas recipe graph");
    assert!(recipe_status.success(), "Cetas recipe preparation failed");

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let capture_dir = out_dir.join("moon-capture");

    if capture_dir.exists() {
        fs::remove_dir_all(&capture_dir).expect("clear MoonBit capture directory");
    }
    fs::create_dir_all(&capture_dir).expect("create MoonBit capture directory");

    let status = Command::new("moon")
        .args(["build", "--target", "native", "--release"])
        .current_dir(&moon_dir)
        .env("MOON_CC_CAPTURE_DIR", &capture_dir)
        .env("MOONBIT_NEW_NATIVE", "0")
        .status()
        .expect("failed to run moon build");
    assert!(status.success(), "MoonBit core build/capture failed");

    let record_path = capture_dir.join("final-link.json");
    let record: FinalLink = serde_json::from_slice(
        &fs::read(&record_path).expect("MoonBit final link invocation was not captured"),
    )
    .expect("invalid MoonBit final-link.json");
    assert!(!record.sources.is_empty(), "Moon final link contained no C source");

    let home = moon_home();
    let mut cbuild = cc::Build::new();
    cbuild.target(&target);
    cbuild.include(home.join("include"));
    cbuild.define("main", Some("cetas_mbt_core_main"));

    let args = &record.expanded_argv;
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if matches!(arg.as_str(), "-I" | "-D" | "-U" | "-isystem") {
            if let Some(value) = args.get(i + 1) {
                cbuild.flag(arg);
                cbuild.flag(value);
                i += 2;
                continue;
            }
        }
        if arg.starts_with("-I")
            || arg.starts_with("-D")
            || arg.starts_with("-U")
            || arg.starts_with("-std=")
            || arg.starts_with("-f")
            || arg.starts_with("-W")
            || arg == "-pthread"
        {
            cbuild.flag(arg);
        }
        i += 1;
    }

    for source in &record.sources {
        cbuild.file(capture_dir.join(&source.copied));
    }
    cbuild.compile("cetas_moon_core");

    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if arg == "-o" {
            i += 2;
            continue;
        }
        if record.output.as_deref() == Some(arg.as_str())
            || record.sources.iter().any(|source| same_source(arg, &source.original))
        {
            i += 1;
            continue;
        }
        if matches!(arg.as_str(), "-I" | "-D" | "-U" | "-isystem") {
            i += 2;
            continue;
        }
        if arg.starts_with("-I")
            || arg.starts_with("-D")
            || arg.starts_with("-U")
            || arg.starts_with("-std=")
            || arg.starts_with("-W")
            || arg.starts_with("-O")
            || arg == "-g"
        {
            i += 1;
            continue;
        }
        println!("cargo:rustc-link-arg={arg}");
        i += 1;
    }
}
