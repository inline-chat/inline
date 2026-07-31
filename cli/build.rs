use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo must provide OUT_DIR"))
        .join("inline-cli-info.plist");
    let version = env!("CARGO_PKG_VERSION");
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Inline CLI</string>
  <key>CFBundleIdentifier</key>
  <string>chat.inline.cli</string>
  <key>CFBundleName</key>
  <string>inline</string>
  <key>CFBundleShortVersionString</key>
  <string>{version}</string>
  <key>CFBundleVersion</key>
  <string>{version}</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>Inline accesses files on a network volume only when you select that volume as an agent workspace or direct a local agent to work with files there.</string>
</dict>
</plist>
"#,
    );
    fs::write(&output, plist).expect("write embedded Inline CLI Info.plist");
    println!(
        "cargo:rustc-link-arg-bin=inline=-Wl,-sectcreate,__TEXT,__info_plist,{}",
        output.display()
    );
}
