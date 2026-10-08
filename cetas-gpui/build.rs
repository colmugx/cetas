use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=CETAS_MOON_CAPTURE");
    println!("cargo:rerun-if-env-changed=MOON_HOME");
    let capture = PathBuf::from(env::var_os("CETAS_MOON_CAPTURE")
        .expect("CETAS_MOON_CAPTURE required: run cetas-gpui/scripts/build-macos.sh"));
    let manifest = capture.join("sources.txt");
    let sources = fs::read_to_string(&manifest).expect("missing captured MoonBit sources.txt");
    let moon = PathBuf::from(env::var_os("MOON_HOME").expect("MOON_HOME must be set"));
    let include = moon.join("include");
    let mut build = cc::Build::new();
    build.include(&include)
        .flag("-fwrapv")
        .flag("-fno-strict-aliasing")
        .flag_if_supported("-Wno-missing-braces")
        .flag_if_supported("-Wno-parentheses")
        // The MoonBit executable's C entry must not collide with Rust main.
        .define("main", Some("cetas_embedded_moon_main"));
    let mut n = 0;
    for line in sources.lines().map(str::trim).filter(|s| !s.is_empty()) {
        if line.contains("..") || line.starts_with('/') {
            panic!("unsafe capture entry: {line}");
        }
        let path = capture.join(line);
        assert!(path.is_file(), "captured C file missing: {}", path.display());
        build.file(&path);
        println!("cargo:rerun-if-changed={}", path.display());
        n += 1;
    }
    assert!(n > 0, "no MoonBit C input files captured");

    // Match the MoonBit C-runtime source set used by ai-passport.mbt.
    // Prefer the installed compiler's runtime sources: never vendor runtime C.
    let runtime = moon.join("lib/runtime");
    let top = moon.join("lib");
    for name in ["runtime.c", "backtrace.c", "env.c", "sync_io.c", "utf.c"] {
        let path = if runtime.join(name).exists() { runtime.join(name) } else { top.join(name) };
        if path.exists() {
            build.file(&path);
            println!("cargo:rerun-if-changed={}", path.display());
        } else if name == "runtime.c" {
            panic!("MoonBit runtime source missing: {}", path.display());
        }
    }
    build.compile("cetas_moonbit");
    println!("cargo:rustc-link-lib=m");
    // Fail at link time if the generated MoonBit entry isn't present.
    println!("cargo:rustc-env=CETAS_COMPILED_MOONBIT=1");
}
