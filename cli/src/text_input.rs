use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use crate::errors::CliError;

const MAX_TEXT_BYTES: u64 = 1024 * 1024;

pub(crate) fn read_text_file(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    if path == Path::new("-") {
        if io::IsTerminal::is_terminal(&io::stdin()) {
            return Err(CliError {
                message: "--text-file - was provided, but stdin is a terminal".into(),
                hint: Some("Pipe UTF-8 text into the command, or use --text-file PATH.".into()),
                examples: vec!["echo \"hello\" | inline message send -c 123 --text-file -".into()],
                ..CliError::stdin_not_piped()
            }
            .into());
        }
        return read_text(io::stdin().lock());
    }
    // Reject directories/devices/FIFOs before opening: a FIFO can block forever.
    let metadata = std::fs::metadata(path)
        .map_err(|error| CliError::invalid_args(format!("Cannot read --text-file: {error}")))?;
    if !metadata.is_file() {
        return Err(CliError::invalid_args("--text-file must be a regular UTF-8 file").into());
    }
    read_text(
        File::open(path)
            .map_err(|error| CliError::invalid_args(format!("Cannot read --text-file: {error}")))?,
    )
}

fn read_text(reader: impl Read) -> Result<String, Box<dyn std::error::Error>> {
    let mut bytes = Vec::new();
    reader.take(MAX_TEXT_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_TEXT_BYTES {
        return Err(CliError::invalid_args("--text-file exceeds the 1 MiB limit").into());
    }
    let text = String::from_utf8(bytes)
        .map_err(|_| CliError::invalid_args("--text-file must contain UTF-8 text"))?;
    if text.trim().is_empty() {
        return Err(CliError::invalid_args("--text-file was empty").into());
    }
    // Unlike legacy --text/--stdin, file input preserves indentation and newlines.
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_code_indentation_and_mention_offsets() {
        let input = "  @Sam\n    code();\n";
        assert_eq!(read_text(input.as_bytes()).unwrap(), input);
    }

    #[test]
    fn rejects_empty_invalid_utf8_and_oversize_without_echoing_content() {
        for input in [
            vec![b' '; 3],
            vec![0xff],
            vec![b'x'; MAX_TEXT_BYTES as usize + 1],
        ] {
            let error = read_text(input.as_slice()).unwrap_err();
            assert_eq!(
                error.downcast_ref::<CliError>().unwrap().code,
                "invalid_args"
            );
        }
        assert!(read_text(vec![b'x'; MAX_TEXT_BYTES as usize].as_slice()).is_ok());
    }

    #[test]
    fn accepts_regular_files_and_rejects_directories_and_missing_paths() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("message.md");
        std::fs::write(&path, "  hello\n").unwrap();
        assert_eq!(read_text_file(&path).unwrap(), "  hello\n");
        assert!(read_text_file(directory.path()).is_err());
        assert!(read_text_file(&directory.path().join("missing")).is_err());
    }
}
