use std::path::PathBuf;

fn main() {
    let manifest_dir =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let proto_dir = manifest_dir.join("..").join("proto");

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
    config
        .compile_protos(&proto_paths, &include_paths)
        .expect("compile protos");
}
