//! Process-lifetime bounded logging for the macOS LaunchAgent host.

use std::io;

use super::BridgePaths;

#[cfg(target_os = "macos")]
pub(super) fn install_bounded_process_logging(paths: &BridgePaths) -> io::Result<()> {
    redirect_descriptor(libc::STDOUT_FILENO, &paths.stdout_log, "bridge-stdout")?;
    redirect_descriptor(libc::STDERR_FILENO, &paths.stderr_log, "bridge-stderr")?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub(super) fn install_bounded_process_logging(_paths: &BridgePaths) -> io::Result<()> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn redirect_descriptor(
    target_descriptor: libc::c_int,
    path: &std::path::Path,
    thread_name: &str,
) -> io::Result<()> {
    use std::fs::File;
    use std::os::fd::FromRawFd;

    let writer = BoundedLogWriter::open(path.to_path_buf(), super::MAX_LOG_FILE_BYTES)?;
    let mut descriptors = [-1, -1];
    // SAFETY: `descriptors` points to two writable integers and every owned
    // descriptor is either transferred into `File` or closed on each path.
    if unsafe { libc::pipe(descriptors.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the pipe call above returned a valid read descriptor owned here.
    let reader = unsafe { File::from_raw_fd(descriptors[0]) };
    // SAFETY: both descriptors are valid and `dup2` atomically replaces the
    // process descriptor. The original pipe writer is closed immediately.
    if unsafe { libc::dup2(descriptors[1], target_descriptor) } == -1 {
        let error = io::Error::last_os_error();
        // SAFETY: this branch still owns the pipe writer descriptor.
        unsafe { libc::close(descriptors[1]) };
        return Err(error);
    }
    // SAFETY: `target_descriptor` now owns the duplicate writer.
    unsafe { libc::close(descriptors[1]) };

    std::thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || writer.copy_from(reader))
        .map(|_| ())
}

#[cfg(any(target_os = "macos", test))]
struct BoundedLogWriter {
    path: std::path::PathBuf,
    file: std::fs::File,
    size: u64,
    maximum_size: u64,
}

#[cfg(any(target_os = "macos", test))]
impl BoundedLogWriter {
    fn open(path: std::path::PathBuf, maximum_size: u64) -> io::Result<Self> {
        use std::fs::OpenOptions;

        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let size = file.metadata()?.len();
        Ok(Self {
            path,
            file,
            size,
            maximum_size,
        })
    }

    fn copy_from(mut self, mut reader: std::fs::File) {
        use std::io::Read;

        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(length) => {
                    let _ = self.write(&buffer[..length]);
                }
            }
        }
    }

    fn write(&mut self, bytes: &[u8]) -> io::Result<()> {
        use std::fs::OpenOptions;
        use std::io::Write;

        if self.size.saturating_add(bytes.len() as u64) > self.maximum_size {
            self.file = OpenOptions::new()
                .write(true)
                .truncate(true)
                .open(&self.path)?;
            self.size = 0;
            let marker = b"[earlier bridge log output truncated]\n";
            if marker.len() as u64 <= self.maximum_size {
                self.file.write_all(marker)?;
                self.size += marker.len() as u64;
            }
        }
        let available = self.maximum_size.saturating_sub(self.size) as usize;
        let bytes = if bytes.len() > available {
            &bytes[bytes.len() - available..]
        } else {
            bytes
        };
        self.file.write_all(bytes)?;
        self.file.flush()?;
        self.size = self.size.saturating_add(bytes.len() as u64);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    use super::*;

    #[test]
    fn writer_truncates_during_the_process_lifetime() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("bridge.log");
        let mut writer = BoundedLogWriter::open(path.clone(), 128).expect("writer");
        writer.write(&[b'a'; 96]).expect("first write");
        writer.write(&[b'b'; 64]).expect("rotating write");
        drop(writer);

        let mut contents = Vec::new();
        std::fs::File::open(&path)
            .expect("log")
            .read_to_end(&mut contents)
            .expect("read log");
        assert!(contents.len() <= 128);
        assert!(contents.starts_with(b"[earlier bridge log output truncated]\n"));
        assert!(contents.ends_with(&[b'b'; 64]));
    }
}
