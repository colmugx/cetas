use std::{env, fs, path::{Path, PathBuf}};

fn main() {
    println!("cargo:rerun-if-env-changed=CETAS_MOON_CAPTURE_DIR");
    let capture = env::var_os("CETAS_MOON_CAPTURE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("generated/moonbit"));
    let manifest = capture.join("sources.txt");
    println!("cargo:rerun-if-changed={}", manifest.display());

    let text = fs::read_to_string(&manifest)
        .unwrap_or_else(|e| panic!("missing captured MoonBit C manifest {}: {e}", manifest.display()));

    let mut build = cc::Build::new();
    build.define("main", Some("cetas_moonbit_main"));
    build.flag_if_supported("-Wno-unused-function");
    if let Some(home) = env::var_os("HOME") {
        build.include(Path::new(&home).join(".moon/include"));
    }
    for rel in text.lines().filter(|line| !line.trim().is_empty()) {
        let path = capture.join(rel);
        println!("cargo:rerun-if-changed={}", path.display());
        build.file(path);
    }
    build.compile("cetas_moonbit");
}
