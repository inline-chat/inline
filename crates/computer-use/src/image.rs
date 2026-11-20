//! Screenshots sized for a model: the long edge capped and JPEG-encoded with
//! macOS's own `sips`, as the engine captures with `screencapture`.

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

/// The long edge models read without resizing on their side.
pub const MAX_EDGE: u32 = 1568;
const JPEG_QUALITY: &str = "80";

pub struct Encoded {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Scales `data` (PNG or JPEG) so its long edge is at most [`MAX_EDGE`], as
/// JPEG. `width` and `height` are the source pixels.
pub fn for_model(data: &[u8], width: u32, height: u32) -> std::io::Result<Encoded> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let stem = format!(
        "inline-computer-use-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let dir = std::env::temp_dir();
    let input = dir.join(format!("{stem}.src"));
    let output = dir.join(format!("{stem}.jpg"));
    let _cleanup = Cleanup(vec![input.clone(), output.clone()]);
    std::fs::write(&input, data)?;
    let (target_width, target_height) = fit(width, height);
    let status = Command::new("/usr/bin/sips")
        .args(["-s", "format", "jpeg", "-s", "formatOptions", JPEG_QUALITY])
        .args(["-z", &target_height.to_string(), &target_width.to_string()])
        .arg(&input)
        .arg("--out")
        .arg(&output)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        return Err(std::io::Error::other(
            "sips could not encode the screenshot",
        ));
    }
    Ok(Encoded {
        data: std::fs::read(&output)?,
        width: target_width,
        height: target_height,
    })
}

/// The size that fits `width` x `height` inside [`MAX_EDGE`], keeping the
/// aspect ratio; never upscales.
pub fn fit(width: u32, height: u32) -> (u32, u32) {
    let long = width.max(height).max(1);
    if long <= MAX_EDGE {
        return (width.max(1), height.max(1));
    }
    let scale = f64::from(MAX_EDGE) / f64::from(long);
    let scaled = |side: u32| ((f64::from(side) * scale).round() as u32).max(1);
    (scaled(width), scaled(height))
}

struct Cleanup(Vec<PathBuf>);

impl Drop for Cleanup {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_caps_the_long_edge_and_keeps_small_images() {
        assert_eq!(fit(3456, 2234), (1568, 1014));
        assert_eq!(fit(2234, 3456), (1014, 1568));
        assert_eq!(fit(800, 600), (800, 600));
    }
}
