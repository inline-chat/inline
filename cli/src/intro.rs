use std::io::{self, Write};

use clap::builder::styling::{AnsiColor, Style, Styles};
use unicode_width::UnicodeWidthStr;

const COMMAND: Style = AnsiColor::BrightBlue.on_default().bold();
const FLAG: Style = AnsiColor::Cyan.on_default();
const VALUE: Style = AnsiColor::Yellow.on_default();
const HEADING: Style = Style::new().bold();
const MUTED: Style = Style::new().dimmed();
const BRAND: Style = AnsiColor::White.on_default();
// Seven rows preserve Days One's open lowercase e; the smaller mark stays balanced.
// Static glyphs keep the start page offline and avoid a runtime font dependency.
const BRAND_FACE: Style = AnsiColor::BrightWhite.on_default();
const BRAND_BEVEL: Style = AnsiColor::BrightCyan.on_default();
const BRAND_DEPTH: Style = AnsiColor::Blue.on_default();
const WORDMARK: &[&str] = &[
    "              ▄▄▖             ▄▄▖ ▗▄▄",
    "▗▟██████▙▖   ▐██▌            ▐██▌ ▝▀▀",
    "██▘▗▄  ▝██   ▐██▌ ▐██▙████▙▖ ▐██▌ ▐██  ███▟████▄  ▗▟█████▄",
    "██ ██   ██   ▐██▌ ▐██▛   ███ ▐██▌ ▐██  ███▘  ▜██▖▗██▌▄▄▖██▙",
    "██▖▝▀  ▗██   ▐██▌ ▐██▌   ███ ▐██▌ ▐██  ███   ▐██▌▐██▛▀▀▀▀▀▀",
    "▝▜██████▛▘   ▐██▌ ▐██▌   ███ ▐██▌ ▐██  ███   ▐██▖ ▜██▄▄▄██▌",
    "              ▀▀▘ ▝▀▀▘   ▀▀▀  ▀▀▘ ▝▀▀  ▀▀▘   ▝▀▀    ▀▀▀▀▀▘",
];

struct Example {
    command: &'static str,
    args: &'static [&'static str],
    description: &'static str,
}

const GROUPS: &[(&str, &[Example])] = &[
    (
        "Start here",
        &[
            Example {
                command: "login",
                args: &[],
                description: "Sign in to Inline",
            },
            Example {
                command: "chat ls",
                args: &[],
                description: "Find a chat or thread",
            },
            Example {
                command: "agents setup",
                args: &[],
                description: "Connect a local agent",
            },
            Example {
                command: "skill install",
                args: &[],
                description: "Install the Codex skill",
            },
        ],
    ),
    (
        "Messages",
        &[
            Example {
                command: "search",
                args: &["release checklist", "-c", "123"],
                description: "Search within a chat",
            },
            Example {
                command: "message send",
                args: &["-c", "123", "-m", "Hello"],
                description: "Send a message",
            },
            Example {
                command: "transcript",
                args: &["-c", "123", "--output", "chat.md"],
                description: "Export chat to Markdown",
            },
        ],
    ),
    (
        "Tools",
        &[
            Example {
                command: "doctor",
                args: &[],
                description: "Check CLI health",
            },
            Example {
                command: "update",
                args: &[],
                description: "Install the latest CLI",
            },
            Example {
                command: "completion",
                args: &["zsh"],
                description: "Generate completions",
            },
        ],
    ),
];

pub(crate) fn help_styles() -> Styles {
    Styles::styled()
        .header(HEADING)
        .usage(HEADING)
        .literal(COMMAND)
        .placeholder(VALUE)
}

pub(crate) fn write(mut writer: impl Write, columns: usize, color: bool) -> io::Result<()> {
    match writer.write_all(render(columns, color).as_bytes()) {
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        result => result,
    }
}

fn render(columns: usize, color: bool) -> String {
    let columns = columns.max(20);
    // Very small panes get a useful doorway, rather than overflowing examples.
    if columns < 32 {
        let mut page = format!(
            "\n{} {}\n\nWork chat + agents\n\n",
            paint("inline", BRAND, color),
            env!("CARGO_PKG_VERSION")
        );
        for example in GROUPS[0].1 {
            page.push_str(&styled_tokens(&example.tokens(), color));
            page.push('\n');
        }
        page.push_str(&format!("\n{}\n\n", paint("inline --help", COMMAND, color)));
        return page;
    }
    let mut page = String::from("\n");
    let wordmark_width = WORDMARK.iter().map(|line| line.width()).max().unwrap_or(0);
    if columns > wordmark_width {
        // Omit the shadow when it would overflow or merge into monochrome lettering.
        let depth = color && columns > wordmark_width + 2;
        render_wordmark(&mut page, color, depth);
    } else {
        page.push_str(&paint("  inline", BRAND, color));
        page.push('\n');
    }
    page.push_str(&format!(
        "  {}\n\n",
        paint(concat!("v", env!("CARGO_PKG_VERSION")), MUTED, color)
    ));
    paragraph(
        &mut page,
        "Work chat and agents, from your terminal.",
        columns,
        HEADING,
        color,
    );
    page.push('\n');

    let command_width = GROUPS
        .iter()
        .flat_map(|(_, examples)| *examples)
        .map(|example| {
            let tokens = example.tokens();
            tokens.iter().map(|(text, _)| text.len()).sum::<usize>() + tokens.len() - 1
        })
        .max()
        .unwrap_or(0);
    let description_width = columns.saturating_sub(4 + command_width + 3);
    for (heading, examples) in GROUPS {
        page.push_str(&format!("  {}\n", paint(heading, HEADING, color)));
        for example in *examples {
            let tokens = example.tokens();
            if description_width >= 22 {
                let command = styled_tokens(&tokens, color);
                let plain_width =
                    tokens.iter().map(|(text, _)| text.len()).sum::<usize>() + tokens.len() - 1;
                let description = wrap_words(example.description, description_width);
                page.push_str(&format!(
                    "    {command}{}{}\n",
                    " ".repeat(command_width - plain_width + 3),
                    paint(&description[0], MUTED, color)
                ));
                for line in description.iter().skip(1) {
                    page.push_str(&format!(
                        "{}{}\n",
                        " ".repeat(4 + command_width + 3),
                        paint(line, MUTED, color)
                    ));
                }
            } else {
                command_lines(&mut page, &tokens, columns, color);
                for line in wrap_words(example.description, columns.saturating_sub(6)) {
                    page.push_str(&format!("      {}\n", paint(&line, MUTED, color)));
                }
            }
        }
        page.push('\n');
    }
    for text in [
        "123 is an example chat ID. Find yours with inline chat ls.",
        "All commands: inline --help",
        "Command help: inline <command> --help",
        "Scripts: --json --compact. Version: -v.",
        "https://inline.chat/docs/cli",
    ] {
        paragraph(&mut page, text, columns, MUTED, color);
    }
    page.push('\n');
    page
}

fn render_wordmark(page: &mut String, color: bool, depth: bool) {
    let glyphs: Vec<Vec<char>> = WORDMARK.iter().map(|line| line.chars().collect()).collect();
    let width = glyphs.iter().map(Vec::len).max().unwrap_or(0);
    for row in 0..glyphs.len() + usize::from(depth) {
        let mut line = String::new();
        let mut current_style = None;
        for column in 0..width + if depth { 2 } else { 0 } {
            let face = glyphs
                .get(row)
                .and_then(|line| line.get(column))
                .copied()
                .unwrap_or(' ');
            let shadow = if depth && row > 0 && column >= 2 {
                glyphs[row - 1].get(column - 2).copied().unwrap_or(' ')
            } else {
                ' '
            };
            let (glyph, style) = if face != ' ' {
                (face, if row < 5 { BRAND_FACE } else { BRAND_BEVEL })
            } else {
                (shadow, BRAND_DEPTH)
            };
            if color && glyph != ' ' && current_style != Some(style) {
                line.push_str(&format!("{style}"));
                current_style = Some(style);
            }
            line.push(glyph);
        }
        page.push(' ');
        page.push_str(line.trim_end());
        if color {
            page.push_str(&format!("{BRAND:#}"));
        }
        page.push('\n');
    }
}

impl Example {
    fn tokens(&self) -> Vec<(String, Style)> {
        std::iter::once(("inline".to_string(), COMMAND))
            .chain(
                self.command
                    .split_whitespace()
                    .map(|part| (part.to_string(), COMMAND)),
            )
            .chain(self.args.iter().map(|arg| {
                (
                    quote_argument(arg),
                    if arg.starts_with('-') { FLAG } else { VALUE },
                )
            }))
            .collect()
    }
}

fn quote_argument(argument: &str) -> String {
    if !argument.is_empty()
        && argument
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || "-_./".contains(ch))
    {
        argument.to_string()
    } else {
        format!("'{}'", argument.replace('\'', "'\\''"))
    }
}

fn styled_tokens(tokens: &[(String, Style)], color: bool) -> String {
    tokens
        .iter()
        .map(|(text, style)| paint(text, *style, color))
        .collect::<Vec<_>>()
        .join(" ")
}

fn command_lines(page: &mut String, tokens: &[(String, Style)], columns: usize, color: bool) {
    let mut line = Vec::new();
    let mut width = 4;
    for token in tokens {
        let extra = token.0.len() + usize::from(!line.is_empty());
        // Reserve two columns for a shell continuation on wrapped lines.
        if !line.is_empty() && width + extra + 2 > columns {
            page.push_str(&format!("    {} \\\n", styled_tokens(&line, color)));
            line.clear();
            width = 4;
        }
        width += token.0.len() + usize::from(!line.is_empty());
        line.push(token.clone());
    }
    page.push_str(&format!("    {}\n", styled_tokens(&line, color)));
}

fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let mut lines = vec![String::new()];
    for word in text.split_whitespace() {
        let line = lines.last_mut().expect("one line");
        if !line.is_empty() && line.len() + 1 + word.len() > width {
            lines.push(word.to_string());
        } else {
            if !line.is_empty() {
                line.push(' ');
            }
            line.push_str(word);
        }
    }
    lines
}

fn paragraph(page: &mut String, text: &str, columns: usize, style: Style, color: bool) {
    for line in wrap_words(text, columns.saturating_sub(2)) {
        page.push_str(&format!("  {}\n", paint(&line, style, color)));
    }
}

fn paint(text: &str, style: Style, color: bool) -> String {
    if color {
        format!("{style}{text}{style:#}")
    } else {
        text.to_string()
    }
}

#[cfg(test)]
pub(crate) fn example_arguments() -> Vec<Vec<&'static str>> {
    GROUPS
        .iter()
        .flat_map(|(_, examples)| *examples)
        .map(|example| {
            std::iter::once("inline")
                .chain(example.command.split_whitespace())
                .chain(example.args.iter().copied())
                .collect()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_fit_common_terminal_widths_and_preserve_examples() {
        for columns in 32..=160 {
            let page = render(columns, false);
            assert!(!page.contains('\x1b'));
            for line in page.lines() {
                assert!(line.width() <= columns, "{columns} columns: {line:?}");
            }
            assert!(page.contains("'release checklist'"));
            assert!(page.contains("chat.md"));
            assert!(page.contains("inline --help"));
        }
    }

    #[test]
    fn brand_preserves_plain_lettering_and_reserves_space_for_depth() {
        let width = WORDMARK.iter().map(|line| line.width()).max().unwrap();
        assert!(!render(width, false).contains(WORDMARK[0]));
        assert!(render(width + 1, false).contains(WORDMARK[0]));
        let plain = render(80, false);
        assert!(WORDMARK.iter().all(|line| plain.contains(line)));
        let ansi = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
        for columns in [width, width + 1, width + 2, width + 3, 80] {
            let page = render(columns, true);
            assert!(
                ansi.replace_all(&page, "")
                    .lines()
                    .all(|line| line.width() <= columns)
            );
            let brand = page.split("Work chat").next().unwrap();
            assert_eq!(brand.contains("\x1b[34m"), columns > width + 2);
            if columns > width {
                assert!(brand.contains("\x1b[97m"));
                assert!(brand.contains("\x1b[96m"));
            }
        }
    }

    #[test]
    fn tiny_panes_have_a_compact_starter_page() {
        for columns in 20..32 {
            let page = render(columns, false);
            assert!(
                page.lines().all(|line| line.width() <= columns),
                "{columns}: {page}"
            );
            assert!(page.contains("inline login"));
            assert!(page.contains("inline skill install"));
            assert!(page.contains("inline --help"));
        }
    }

    #[test]
    fn styling_does_not_change_help_or_copyable_commands() {
        let ansi = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
        for columns in [40, 80, 120] {
            let plain = render(columns, false);
            let styled = render(columns, true);
            assert!(styled.contains('\x1b'));
            // The decorative shadow is color-only; all help and commands remain identical.
            let styled_help = styled.split("Work chat").nth(1).unwrap();
            let plain_help = plain.split("Work chat").nth(1).unwrap();
            assert_eq!(ansi.replace_all(styled_help, ""), plain_help);
        }
    }

    #[test]
    fn wrapped_commands_keep_shell_tokens_intact() {
        for columns in [32, 40, 60] {
            for (_, examples) in GROUPS {
                for example in *examples {
                    let tokens = example.tokens();
                    let mut wrapped = String::new();
                    command_lines(&mut wrapped, &tokens, columns, false);
                    assert_eq!(
                        wrapped.replace(" \\\n    ", " ").trim(),
                        styled_tokens(&tokens, false)
                    );
                }
            }
        }
    }

    #[test]
    fn broken_pipes_are_quiet_and_other_io_errors_propagate() {
        struct Fails(io::ErrorKind);
        impl Write for Fails {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::Error::from(self.0))
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        assert!(write(Fails(io::ErrorKind::BrokenPipe), 80, false).is_ok());
        assert_eq!(
            write(Fails(io::ErrorKind::PermissionDenied), 80, false)
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
