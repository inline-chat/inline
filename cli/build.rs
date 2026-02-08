use std::{
    fs,
    path::{Path, PathBuf},
};

fn collect_rerun_paths(proto_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![proto_dir.to_path_buf()];

    while let Some(dir) = stack.pop() {
        out.push(dir.clone());

        let entries = fs::read_dir(&dir).unwrap_or_else(|err| {
            panic!("read_dir {}: {}", dir.display(), err);
        });

        for entry in entries {
            let entry = entry.unwrap_or_else(|err| {
                panic!("read_dir entry {}: {}", dir.display(), err);
            });

            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|ext| ext.to_str()) == Some("proto") {
                out.push(path);
            }
        }
    }

    out.sort();
    out
}

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let proto_dir = manifest_dir.join("..").join("proto");
    let proto_dir = proto_dir.canonicalize().unwrap_or(proto_dir);

    for path in collect_rerun_paths(&proto_dir) {
        println!("cargo:rerun-if-changed={}", path.display());
    }

    let protos = [
        proto_dir.join("core.proto"),
        proto_dir.join("client.proto"),
        proto_dir.join("server.proto"),
    ];

    let proto_paths: Vec<_> = protos
        .iter()
        .map(|path| path.to_string_lossy().to_string())
        .collect();

    let include_paths = [proto_dir.to_string_lossy().to_string()];

    let mut config = prost_build::Config::new();
    config.type_attribute(".", "#[derive(serde::Serialize, serde::Deserialize)]");
    config.compile_protos(&proto_paths, &include_paths).expect("compile protos");
}
