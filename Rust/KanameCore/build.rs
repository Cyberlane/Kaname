fn main() -> Result<(), Box<dyn std::error::Error>> {
    let inputs = [
        "../../proto/kaname/v1/common.proto",
        "../../proto/kaname/v1/command.proto",
        "../../proto/kaname/v1/event.proto",
        "../../proto/kaname/v1/replay.proto",
        "../../proto/kaname/v1/approval.proto",
        "../../proto/kaname/v1/queue.proto",
        "../../proto/kaname/v1/notification.proto",
        "../../proto/kaname/v1/sync.proto",
        "../../proto/kaname/v1/workflow.proto",
    ];
    let protoc = protoc_bin_vendored::protoc_bin_path()?;
    let mut config = prost_build::Config::new();
    config.protoc_executable(protoc);
    config.file_descriptor_set_path(
        std::path::PathBuf::from(std::env::var("OUT_DIR")?).join("kaname-v1.desc"),
    );
    config.compile_protos(&inputs, &["../../proto"])?;
    for input in inputs {
        println!("cargo:rerun-if-changed={input}");
    }
    Ok(())
}
