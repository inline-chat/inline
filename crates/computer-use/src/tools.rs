//! The tools agents see. Inline owns these names and shapes; the engine
//! behind them can change.

use serde_json::{Value, json};

/// How an agent should work with these tools, sent as the server's MCP
/// instructions.
pub const INSTRUCTIONS: &str = "\
Use these tools to operate apps on this Mac. Prefer an app's own CLI, API or \
connector when one exists. Loop: open_app or list_apps, then snapshot the app \
to get its accessibility tree, act on an element by its ref (click, type_text, \
set_value, scroll), and snapshot again to check the result. Refs look like \
@s1a2b3c4:e7 and go stale when the UI changes: on STALE_REF, snapshot again. \
Ref actions run in the background without moving the user's cursor or \
focus. When an element has no ref (canvas, custom drawing), take a \
screenshot and click by x,y in that screenshot's pixels; coordinate clicks \
bring the app forward. Use find to locate elements in large trees.";

/// One tool: its name, description and JSON input schema.
pub struct Tool {
    pub name: &'static str,
    pub description: &'static str,
    pub read_only: bool,
    pub schema: fn() -> Value,
}

pub const TOOLS: &[Tool] = &[
    Tool {
        name: "list_apps",
        description: "List the running apps (the ones in the Dock).",
        read_only: true,
        schema: || object(json!({}), &[]),
    },
    Tool {
        name: "list_windows",
        description: "List open windows, optionally for one app, with ids and bounds.",
        read_only: true,
        schema: || object(json!({ "app": APP }), &[]),
    },
    Tool {
        name: "open_app",
        description: "Open an app, or bring it forward if it is already running, and return its window.",
        read_only: false,
        schema: || {
            object(
                json!({ "app": { "type": "string", "description": "App name (\"Safari\") or bundle id (\"com.apple.Safari\")." } }),
                &["app"],
            )
        },
    },
    Tool {
        name: "snapshot",
        description: "Read an app window's accessibility tree. Elements you can act on carry a ref. \
Set screenshot to also get an image of the window.",
        read_only: true,
        schema: || {
            object(
                json!({
                    "app": APP,
                    "window_id": WINDOW_ID,
                    "root": { "type": "string", "description": "Start from this ref to read one part of the tree." },
                    "all": { "type": "boolean", "description": "Include non-interactive elements (text, groups). Default false." },
                    "max_depth": { "type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10." },
                    "screenshot": { "type": "boolean", "description": "Also return a screenshot of the window." }
                }),
                &[],
            )
        },
    },
    Tool {
        name: "find",
        description: "Find elements by role, name, value or text and return their refs. Faster than reading a large tree.",
        read_only: true,
        schema: || {
            object(
                json!({
                    "app": APP,
                    "window_id": WINDOW_ID,
                    "role": { "type": "string", "description": "Accessibility role, e.g. button, textfield, link, checkbox." },
                    "name": { "type": "string" },
                    "value": { "type": "string" },
                    "text": { "type": "string", "description": "Matches name, value or description." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20." }
                }),
                &[],
            )
        },
    },
    Tool {
        name: "click",
        description: "Click an element by ref (in the background), or at x,y in the last screenshot's pixels (brings the app forward).",
        read_only: false,
        schema: || {
            object(
                json!({
                    "ref": REF,
                    "x": { "type": "number", "description": "Pixel x in the last screenshot." },
                    "y": { "type": "number", "description": "Pixel y in the last screenshot." },
                    "button": { "type": "string", "enum": ["left", "right"], "description": "Default left." },
                    "count": { "type": "integer", "enum": [1, 2, 3], "description": "1 click, 2 double, 3 triple. Default 1." }
                }),
                &[],
            )
        },
    },
    Tool {
        name: "type_text",
        description: "Type text into a text field or editor by ref.",
        read_only: false,
        schema: || {
            object(
                json!({ "ref": REF, "text": { "type": "string" } }),
                &["ref", "text"],
            )
        },
    },
    Tool {
        name: "set_value",
        description: "Replace an element's value (text field, slider, picker) by ref.",
        read_only: false,
        schema: || {
            object(
                json!({ "ref": REF, "value": { "type": "string" } }),
                &["ref", "value"],
            )
        },
    },
    Tool {
        name: "press",
        description: "Press a key or shortcut, e.g. return, escape, tab, cmd+t, cmd+shift+n. With app, keys go to that app.",
        read_only: false,
        schema: || {
            object(
                json!({ "keys": { "type": "string" }, "app": APP, "window_id": WINDOW_ID }),
                &["keys"],
            )
        },
    },
    Tool {
        name: "scroll",
        description: "Scroll a scrollable element (list, page, table) by ref.",
        read_only: false,
        schema: || {
            object(
                json!({
                    "ref": REF,
                    "direction": { "type": "string", "enum": ["up", "down", "left", "right"] },
                    "amount": { "type": "integer", "minimum": 1, "maximum": 50, "description": "Default 3." }
                }),
                &["ref", "direction"],
            )
        },
    },
    Tool {
        name: "screenshot",
        description: "Take a screenshot of an app's window, or of the main display without app. Coordinates for click are this image's pixels.",
        read_only: true,
        schema: || object(json!({ "app": APP, "window_id": WINDOW_ID }), &[]),
    },
    Tool {
        name: "wait",
        description: "Wait for the UI to settle, up to 10 seconds.",
        read_only: true,
        schema: || {
            object(
                json!({ "ms": { "type": "integer", "minimum": 1, "maximum": 10000 } }),
                &["ms"],
            )
        },
    },
];

const APP: Value = Value::Null;
const WINDOW_ID: Value = Value::Null;
const REF: Value = Value::Null;

fn property(key: &str) -> Value {
    match key {
        "app" => json!({ "type": "string", "description": "App name or bundle id." }),
        "window_id" => json!({ "type": "string", "description": "A window id from list_windows." }),
        _ => json!({ "type": "string", "description": "An element ref from snapshot or find." }),
    }
}

/// An object schema; `null` placeholders become the shared properties.
fn object(properties: Value, required: &[&str]) -> Value {
    let mut properties = properties;
    if let Some(map) = properties.as_object_mut() {
        for (key, value) in map.iter_mut() {
            if value.is_null() {
                *value = property(key);
            }
        }
    }
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    })
}

/// The tools as MCP `tools/list` entries.
pub fn list() -> Vec<Value> {
    TOOLS
        .iter()
        .map(|tool| {
            json!({
                "name": tool.name,
                "description": tool.description,
                "inputSchema": (tool.schema)(),
                "annotations": { "readOnlyHint": tool.read_only },
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_an_object_schema_with_known_required_fields() {
        for tool in TOOLS {
            let schema = (tool.schema)();
            assert_eq!(schema["type"], "object", "{}", tool.name);
            let properties = schema["properties"].as_object().unwrap();
            for value in properties.values() {
                assert!(
                    value.get("type").is_some(),
                    "{}: untyped property",
                    tool.name
                );
            }
            for required in schema["required"].as_array().unwrap() {
                assert!(
                    properties.contains_key(required.as_str().unwrap()),
                    "{}: requires unknown {required}",
                    tool.name
                );
            }
        }
    }

    #[test]
    fn names_are_unique() {
        let mut names: Vec<_> = TOOLS.iter().map(|tool| tool.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), TOOLS.len());
    }
}
