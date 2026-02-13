use serde_json::Value;
use std::process::Command;

fn run_inline(args: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(args)
        .output()
        .expect("failed to execute inline binary");

    assert!(
        output.status.success(),
        "inline failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    serde_json::from_slice(&output.stdout).expect("stdout should be valid json")
}

#[test]
fn query_path_aliases_work_on_command_output() {
    let value = run_inline(&["doctor", "--json", "--query-path", "cfg.apiBaseUrl"]);
    let Some(url) = value.as_str() else {
        panic!("expected string url, got {value}");
    };
    assert!(url.starts_with("http"));
}

#[test]
fn quoted_bracket_keys_are_not_rewritten() {
    let value = run_inline(&["doctor", "--json", "--query-path", "cfg[\"apiBaseUrl\"]"]);
    assert!(value.as_str().is_some());
}

#[test]
fn mixed_case_tokens_are_not_rewritten() {
    let value = run_inline(&["doctor", "--json", "--query-path", "cfg.ApiBaseUrl"]);
    assert!(value.is_null());
}
