//! The tools on agent-desktop's macOS engine.

use agent_desktop_core::commands::{
    self, find::FindArgs, find::FindFilterArgs, find::FindSelectionArgs, helpers::RefArgs,
    launch::LaunchArgs, list_apps::ListAppsArgs, list_windows::ListWindowsArgs,
    mouse_click::MouseClickArgs, press::PressArgs, screenshot::ScreenshotArgs, scroll::ScrollArgs,
    set_value::SetValueArgs, snapshot::SnapshotArgs, type_text::TypeArgs,
};
use agent_desktop_core::system::launch_options::LaunchOptions;
use agent_desktop_core::{
    AppError, CommandContext, Direction, MouseButton, PlatformAdapter, SnapshotSurface,
};
use agent_desktop_macos::MacOSAdapter;
use base64::Engine as _;
use serde_json::{Value, json};

use crate::image;
use crate::server::Output;

/// Text past this is cut, with a pointer to narrower reads.
const MAX_TEXT_CHARS: usize = 60_000;
const STATE_HOME_ENV: &str = "AGENT_DESKTOP_HOME";

/// Where the last screenshot sits on screen, so a click at its pixels lands
/// at the same point.
#[derive(Clone, Copy)]
struct Shot {
    origin_x: f64,
    origin_y: f64,
    points_per_pixel: f64,
}

pub(crate) struct Engine {
    adapter: MacOSAdapter,
    /// Strict background delivery: no cursor or focus changes.
    background: CommandContext,
    /// Physical input for coordinate clicks, which bring the app forward.
    foreground: CommandContext,
    last_shot: Option<Shot>,
}

impl Engine {
    pub fn new() -> Result<Self, Output> {
        if std::env::var_os(STATE_HOME_ENV).is_none()
            && let Some(home) = std::env::var_os("HOME")
        {
            let root = std::path::Path::new(&home).join("Library/Caches/inline-computer-use");
            let _ = std::fs::create_dir_all(&root);
            // SAFETY: the server is single-threaded and the engine reads this
            // only from calls made after this point.
            unsafe { std::env::set_var(STATE_HOME_ENV, root) };
        }
        // One snapshot namespace per server, so agents keep their own refs.
        let session = format!("inline-{}", std::process::id());
        let background = CommandContext::new(Some(session), None, false)
            .map_err(|error| failure(&error))?
            .with_headed(false);
        let foreground = background
            .for_batch_item(None)
            .map_err(|error| failure(&error))?
            .with_headed(true);
        Ok(Self {
            adapter: MacOSAdapter::new(),
            background,
            foreground,
            last_shot: None,
        })
    }

    pub fn call(&mut self, name: &str, args: &Value) -> Output {
        match self.dispatch(name, args) {
            Ok(output) => output,
            Err(Failure::App(error)) => failure(&error),
            Err(Failure::Input(message)) => Output::error(message),
        }
    }

    fn dispatch(&mut self, name: &str, args: &Value) -> Result<Output, Failure> {
        let adapter: &dyn PlatformAdapter = &self.adapter;
        let ctx = &self.background;
        let data = match name {
            "list_apps" => user_apps(commands::list_apps::execute(
                ListAppsArgs {
                    app: None,
                    timeout_ms: None,
                },
                adapter,
            )?),
            "list_windows" => commands::list_windows::execute(
                ListWindowsArgs {
                    app: opt(args, "app"),
                    timeout_ms: None,
                },
                adapter,
            )?,
            "open_app" => commands::launch::execute(
                LaunchArgs {
                    app: req(args, "app")?,
                    options: LaunchOptions {
                        activate: true,
                        timeout_ms: 10_000,
                        ..LaunchOptions::default()
                    },
                },
                adapter,
            )?,
            "snapshot" => {
                let tree = scoped(ctx, "snapshot", false, || {
                    Ok(commands::snapshot::execute(
                        SnapshotArgs {
                            app: opt(args, "app"),
                            window_id: opt(args, "window_id"),
                            max_depth: number(args, "max_depth")
                                .map_or(10, |n| n.clamp(1, 50) as u8),
                            include_bounds: false,
                            interactive_only: !flag(args, "all"),
                            compact: true,
                            surface: SnapshotSurface::Window,
                            skeleton: false,
                            root_ref: opt(args, "root"),
                            timeout_ms: None,
                            force_electron_a11y: false,
                        },
                        adapter,
                        ctx,
                    )?)
                })?;
                let mut output = Output::text(compact(&tree));
                if flag(args, "screenshot") {
                    output.content.extend(self.screenshot(args)?.content);
                }
                return Ok(output);
            }
            "find" => scoped(ctx, "find", false, || {
                Ok(commands::find::execute(
                    FindArgs {
                        app: opt(args, "app"),
                        window_id: opt(args, "window_id"),
                        root: None,
                        surface: SnapshotSurface::Window,
                        filter: FindFilterArgs {
                            role: opt(args, "role"),
                            name: opt(args, "name"),
                            description: None,
                            native_id: None,
                            value: opt(args, "value"),
                            text: opt(args, "text"),
                            exact: false,
                        },
                        states: Vec::new(),
                        selection: FindSelectionArgs {
                            count: false,
                            first: false,
                            last: false,
                            nth: None,
                            limit: Some(
                                number(args, "limit").map_or(20, |n| n.clamp(1, 200) as usize),
                            ),
                        },
                        timeout_ms: None,
                    },
                    adapter,
                    ctx,
                )?)
            })?,
            "click" => return self.click(args),
            "type_text" => scoped(ctx, "type", true, || {
                Ok(commands::type_text::execute(
                    TypeArgs {
                        ref_id: req(args, "ref")?,
                        text: req(args, "text")?,
                        timeout_ms: None,
                        interval_ms: None,
                    },
                    adapter,
                    ctx,
                )?)
            })?,
            "set_value" => scoped(ctx, "set-value", true, || {
                Ok(commands::set_value::execute(
                    SetValueArgs {
                        ref_id: req(args, "ref")?,
                        value: req(args, "value")?,
                        timeout_ms: None,
                    },
                    adapter,
                    ctx,
                )?)
            })?,
            "press" => scoped(ctx, "press", true, || {
                Ok(commands::press::execute(
                    PressArgs {
                        combo: req(args, "keys")?,
                        app: opt(args, "app"),
                        window_id: opt(args, "window_id"),
                        force: false,
                    },
                    adapter,
                    ctx,
                )?)
            })?,
            "scroll" => scoped(ctx, "scroll", true, || {
                Ok(commands::scroll::execute(
                    ScrollArgs {
                        ref_id: req(args, "ref")?,
                        direction: direction(args)?,
                        amount: number(args, "amount").map_or(3, |n| n.clamp(1, 50) as u32),
                        timeout_ms: None,
                    },
                    adapter,
                    ctx,
                )?)
            })?,
            "screenshot" => return self.screenshot(args),
            "wait" => {
                let ms = number(args, "ms").unwrap_or(500).clamp(1, 10_000);
                std::thread::sleep(std::time::Duration::from_millis(ms as u64));
                json!({ "waited_ms": ms })
            }
            other => return Err(Failure::Input(format!("unknown tool: {other}"))),
        };
        Ok(Output::text(compact(&data)))
    }

    fn click(&mut self, args: &Value) -> Result<Output, Failure> {
        let adapter: &dyn PlatformAdapter = &self.adapter;
        let right = args.get("button").and_then(Value::as_str) == Some("right");
        let count = number(args, "count").unwrap_or(1).clamp(1, 3);
        if let Some(ref_id) = opt(args, "ref") {
            let ctx = &self.background;
            let target = RefArgs {
                ref_id,
                timeout_ms: None,
            };
            let data = scoped(ctx, "click", true, || {
                Ok(match (right, count) {
                    (true, _) => commands::right_click::execute(target, adapter, ctx)?,
                    (false, 2) => commands::double_click::execute(target, adapter, ctx)?,
                    (false, 3) => commands::triple_click::execute(target, adapter, ctx)?,
                    _ => commands::click::execute(target, adapter, ctx)?,
                })
            })?;
            return Ok(Output::text(compact(&data)));
        }
        let (Some(x), Some(y)) = (float(args, "x"), float(args, "y")) else {
            return Err(Failure::Input("click needs a ref, or x and y".into()));
        };
        let Some(shot) = self.last_shot else {
            return Err(Failure::Input(
                "take a screenshot first: x and y are pixels in the last screenshot".into(),
            ));
        };
        let screen_x = shot.origin_x + x * shot.points_per_pixel;
        let screen_y = shot.origin_y + y * shot.points_per_pixel;
        let ctx = &self.foreground;
        let data = scoped(ctx, "mouse-click", true, || {
            Ok(commands::mouse_click::execute(
                MouseClickArgs {
                    x: screen_x,
                    y: screen_y,
                    button: if right {
                        MouseButton::Right
                    } else {
                        MouseButton::Left
                    },
                    count: count as u32,
                    modifiers: Vec::new(),
                },
                adapter,
                ctx,
            )?)
        })?;
        Ok(Output::text(compact(&data)))
    }

    /// A window screenshot (the app's focused or first visible window), or
    /// the main display without an app.
    fn screenshot(&mut self, args: &Value) -> Result<Output, Failure> {
        let adapter: &dyn PlatformAdapter = &self.adapter;
        let app = opt(args, "app");
        let mut window_id = opt(args, "window_id");
        let mut origin = None;
        if app.is_some() || window_id.is_some() {
            let windows = commands::list_windows::execute(
                ListWindowsArgs {
                    app: app.clone(),
                    timeout_ms: None,
                },
                adapter,
            )?;
            let window = pick_window(&windows, window_id.as_deref()).ok_or_else(|| {
                Failure::Input(
                    "no visible window to capture; open_app or list_windows first".into(),
                )
            })?;
            window_id = window["id"].as_str().map(str::to_owned);
            let bounds = &window["bounds"];
            origin = Some((
                bounds["x"].as_f64().unwrap_or(0.0),
                bounds["y"].as_f64().unwrap_or(0.0),
                bounds["width"].as_f64().unwrap_or(0.0),
            ));
        }
        let shot = commands::screenshot::execute(
            ScreenshotArgs {
                app: if window_id.is_some() { None } else { app },
                window_id,
                screen: origin.is_none().then_some(0),
                output_path: None,
            },
            adapter,
        )?;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(shot["data"].as_str().unwrap_or_default())
            .map_err(|error| Failure::Input(format!("screenshot data was not base64: {error}")))?;
        let width = shot["width"].as_u64().unwrap_or(0) as u32;
        let height = shot["height"].as_u64().unwrap_or(0) as u32;
        let scale = shot["scale_factor"]
            .as_f64()
            .filter(|s| *s > 0.0)
            .unwrap_or(1.0);
        let encoded = image::for_model(&raw, width, height)
            .map_err(|error| Failure::Input(format!("could not encode the screenshot: {error}")))?;
        let (origin_x, origin_y, points_wide) =
            origin.unwrap_or((0.0, 0.0, f64::from(width) / scale));
        self.last_shot = Some(Shot {
            origin_x,
            origin_y,
            points_per_pixel: points_wide / f64::from(encoded.width.max(1)),
        });
        Ok(Output {
            content: vec![
                json!({
                    "type": "image",
                    "mimeType": "image/jpeg",
                    "data": base64::engine::general_purpose::STANDARD.encode(&encoded.data),
                }),
                json!({
                    "type": "text",
                    "text": format!(
                        "Screenshot {}x{} px. click x,y use these pixels.",
                        encoded.width, encoded.height
                    ),
                }),
            ],
            is_error: false,
        })
    }
}

/// Only the apps a person uses (dock apps), not background agents or
/// command-line processes.
fn user_apps(mut data: Value) -> Value {
    if let Some(apps) = data.get_mut("apps").and_then(Value::as_array_mut) {
        apps.retain(|app| app["presentation"] == "foreground");
        for app in apps.iter_mut() {
            if let Some(app) = app.as_object_mut() {
                app.remove("process_instance");
                app.remove("presentation");
            }
        }
    }
    data
}

/// The window to capture: the one asked for, else the focused visible one,
/// else the first visible one.
fn pick_window<'a>(windows: &'a Value, id: Option<&str>) -> Option<&'a Value> {
    let windows = windows.as_array()?;
    if let Some(id) = id {
        return windows.iter().find(|window| window["id"] == id);
    }
    let visible = |window: &&Value| window["visible"].as_bool().unwrap_or(true);
    windows
        .iter()
        .filter(visible)
        .find(|window| window["is_focused"].as_bool() == Some(true))
        .or_else(|| windows.iter().find(visible))
}

/// Runs one command inside the engine's command scope (trace, deadline).
fn scoped(
    ctx: &CommandContext,
    command: &'static str,
    mutating: bool,
    run: impl FnOnce() -> Result<Value, Failure>,
) -> Result<Value, Failure> {
    let scope = if mutating {
        ctx.mutating_command_scope(command)?
    } else {
        ctx.command_scope(command)?
    };
    match run() {
        Ok(value) => {
            let result: Result<Value, AppError> = Ok(value);
            scope.complete(&result)?;
            result.map_err(Failure::from)
        }
        Err(Failure::App(error)) => {
            let result: Result<Value, AppError> = Err(*error);
            let _ = scope.complete(&result);
            result.map_err(Failure::from)
        }
        Err(input) => Err(input),
    }
}

enum Failure {
    App(Box<AppError>),
    Input(String),
}

impl From<AppError> for Failure {
    fn from(error: AppError) -> Self {
        Self::App(Box::new(error))
    }
}

fn failure(error: &AppError) -> Output {
    let mut body = json!({ "code": error.code(), "message": error.to_string() });
    if let Some(suggestion) = error.suggestion() {
        body["suggestion"] = json!(suggestion);
    }
    Output::error(body.to_string())
}

fn compact(value: &Value) -> String {
    let text = value.to_string();
    if text.len() <= MAX_TEXT_CHARS {
        return text;
    }
    let mut end = MAX_TEXT_CHARS;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!(
        "{}\n[cut at {MAX_TEXT_CHARS} chars: snapshot with root set to a ref, or use find]",
        &text[..end]
    )
}

fn opt(args: &Value, key: &str) -> Option<String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn req(args: &Value, key: &str) -> Result<String, Failure> {
    // Text may be all spaces on purpose; only refs and names are trimmed.
    match key {
        "text" | "value" => args.get(key).and_then(Value::as_str).map(str::to_owned),
        _ => opt(args, key),
    }
    .ok_or_else(|| Failure::Input(format!("missing {key}")))
}

fn number(args: &Value, key: &str) -> Option<i64> {
    args.get(key).and_then(Value::as_i64)
}

fn float(args: &Value, key: &str) -> Option<f64> {
    args.get(key).and_then(Value::as_f64)
}

fn flag(args: &Value, key: &str) -> bool {
    args.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn direction(args: &Value) -> Result<Direction, Failure> {
    match args.get("direction").and_then(Value::as_str) {
        Some("up") => Ok(Direction::Up),
        Some("down") => Ok(Direction::Down),
        Some("left") => Ok(Direction::Left),
        Some("right") => Ok(Direction::Right),
        _ => Err(Failure::Input(
            "direction must be up, down, left or right".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_window_prefers_the_named_then_focused_then_first_visible() {
        let windows = json!([
            { "id": "w-1", "visible": false, "is_focused": true },
            { "id": "w-2", "visible": true, "is_focused": false },
            { "id": "w-3", "visible": true, "is_focused": true },
        ]);
        assert_eq!(pick_window(&windows, Some("w-1")).unwrap()["id"], "w-1");
        assert_eq!(pick_window(&windows, None).unwrap()["id"], "w-3");
        let unfocused = json!([{ "id": "w-4", "visible": true }]);
        assert_eq!(pick_window(&unfocused, None).unwrap()["id"], "w-4");
        assert!(pick_window(&json!([]), None).is_none());
    }

    #[test]
    fn user_apps_keeps_foreground_apps_only() {
        let data = json!({ "apps": [
            { "name": "Safari", "presentation": "foreground", "process_instance": "p1" },
            { "name": "1Password Helper", "presentation": "background" },
            { "name": "claude" },
        ]});
        assert_eq!(user_apps(data), json!({ "apps": [{ "name": "Safari" }] }));
    }

    #[test]
    fn compact_cuts_long_text_with_a_pointer() {
        let long = Value::String("x".repeat(MAX_TEXT_CHARS + 10));
        let text = compact(&long);
        assert!(text.ends_with("or use find]"));
        assert!(text.len() < MAX_TEXT_CHARS + 120);
    }

    #[test]
    fn text_arguments_keep_their_spaces() {
        let args = json!({ "text": "  ", "ref": "  @s1:e2 " });
        assert_eq!(req(&args, "text").ok(), Some("  ".to_owned()));
        assert_eq!(req(&args, "ref").ok(), Some("@s1:e2".to_owned()));
    }
}
