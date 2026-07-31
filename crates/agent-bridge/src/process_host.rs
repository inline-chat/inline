//! Crash-surviving provider process ownership for Unix user services.

use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessHostConfig {
    pub executable: PathBuf,
    pub lock_file: PathBuf,
}

#[cfg(unix)]
fn try_lock(file: &File) -> io::Result<bool> {
    use std::os::fd::AsRawFd;

    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if matches!(error.raw_os_error(), Some(code) if code == libc::EWOULDBLOCK || code == libc::EAGAIN)
    {
        Ok(false)
    } else {
        Err(error)
    }
}

#[cfg(unix)]
fn unlock(file: &File) {
    use std::os::fd::AsRawFd;

    unsafe {
        libc::flock(file.as_raw_fd(), libc::LOCK_UN);
    }
}

#[cfg(unix)]
fn open_lock_file(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "provider lock has no parent")
    })?;
    if !parent.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "provider lock parent is unavailable",
        ));
    }
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

#[cfg(unix)]
fn read_process_group(file: &mut File) -> io::Result<i32> {
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.take(32).read_to_end(&mut bytes)?;
    let value = std::str::from_utf8(&bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid provider lock"))?
        .trim();
    let process_group = value
        .parse::<i32>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid provider process id"))?;
    if process_group <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsafe provider process group",
        ));
    }
    Ok(process_group)
}

#[cfg(unix)]
fn signal_process_group(process_group: i32, signal: i32) -> io::Result<()> {
    let result = unsafe { libc::kill(-process_group, signal) };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}

#[cfg(unix)]
fn process_group_exists(process_group: i32) -> io::Result<bool> {
    let result = unsafe { libc::kill(-process_group, 0) };
    if result == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        Some(libc::EPERM) => Ok(true),
        _ => Err(error),
    }
}

/// Reaps a provider group left behind when the service itself was force-killed.
/// A held private file lock proves the recorded group still belongs to the old
/// provider host; a free lock is never used as authority to signal a PID.
#[cfg(unix)]
pub async fn reap_stale_process_host(path: &Path) -> io::Result<bool> {
    let mut file = match open_lock_file(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if try_lock(&file)? {
        file.set_len(0)?;
        unlock(&file);
        return Ok(false);
    }

    let supervisor_group = read_process_group(&mut file)?;
    signal_process_group(supervisor_group, libc::SIGTERM)?;
    let graceful_deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    while tokio::time::Instant::now() < graceful_deadline {
        if try_lock(&file)? {
            file.set_len(0)?;
            unlock(&file);
            return Ok(true);
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "stale provider supervisor did not stop; refusing to launch a duplicate",
    ))
}

#[cfg(not(unix))]
pub async fn reap_stale_process_host(_path: &Path) -> io::Result<bool> {
    Ok(false)
}

#[cfg(unix)]
static PROCESS_HOST_SIGNAL: AtomicI32 = AtomicI32::new(0);

#[cfg(unix)]
extern "C" fn record_process_host_signal(signal: i32) {
    PROCESS_HOST_SIGNAL.store(signal, Ordering::Relaxed);
}

#[cfg(unix)]
fn install_process_host_signal_handlers() -> io::Result<()> {
    PROCESS_HOST_SIGNAL.store(0, Ordering::Relaxed);
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        let handler = record_process_host_signal as *const () as libc::sighandler_t;
        let previous = unsafe { libc::signal(signal, handler) };
        if previous == libc::SIG_ERR {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn reset_provider_signal_handlers() -> io::Result<()> {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        if unsafe { libc::signal(signal, libc::SIG_DFL) } == libc::SIG_ERR {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(unix)]
fn wait_for_process_group_exit(process_group: i32, timeout: Duration) -> io::Result<bool> {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if !process_group_exists(process_group)? {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Ok(!process_group_exists(process_group)?)
}

#[cfg(unix)]
fn cleanup_provider_group(process_group: i32) -> io::Result<()> {
    signal_process_group(process_group, libc::SIGTERM)?;
    if wait_for_process_group_exit(process_group, Duration::from_millis(250))? {
        return Ok(());
    }
    signal_process_group(process_group, libc::SIGKILL)?;
    if wait_for_process_group_exit(process_group, Duration::from_millis(500))? {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "provider process group did not stop",
        ))
    }
}

#[cfg(unix)]
fn supervise_provider_process(
    child: &mut std::process::Child,
    process_group: i32,
) -> io::Result<std::process::ExitStatus> {
    let mut termination_deadline = None;
    let mut forced = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        let signal = PROCESS_HOST_SIGNAL.swap(0, Ordering::Relaxed);
        if signal != 0 && termination_deadline.is_none() {
            signal_process_group(process_group, signal)?;
            termination_deadline = Some(std::time::Instant::now() + Duration::from_secs(1));
        }
        if termination_deadline.is_some_and(|deadline| std::time::Instant::now() >= deadline)
            && !forced
        {
            signal_process_group(process_group, libc::SIGKILL)?;
            forced = true;
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    cleanup_provider_group(process_group)?;
    Ok(status)
}

/// Runs a tiny supervisor which alone retains the private ownership lock. The
/// real provider gets its own process group and closes the lock on `exec`, so
/// descendants cannot extend or transfer the bridge's ownership proof.
#[cfg(unix)]
pub fn run_process_host(lock_file: &Path, command: &[OsString]) -> io::Result<()> {
    use std::os::unix::process::CommandExt;

    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "provider command is empty"))?;
    let process_id = i32::try_from(std::process::id())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "provider process id overflow"))?;
    let process_group = unsafe { libc::getpgrp() };
    if process_group != process_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "provider process host must own its process group",
        ));
    }
    let mut lock = open_lock_file(lock_file)?;
    if !try_lock(&lock)? {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "provider process host is already active",
        ));
    }
    install_process_host_signal_handlers()?;
    lock.set_len(0)?;
    lock.seek(SeekFrom::Start(0))?;
    writeln!(lock, "{process_id}")?;
    lock.sync_all()?;

    let mut provider = std::process::Command::new(program);
    provider.args(arguments).process_group(0);
    unsafe {
        provider.pre_exec(reset_provider_signal_handlers);
    }
    let mut child = provider.spawn()?;
    let provider_group = i32::try_from(child.id())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "provider process id overflow"))?;
    let status = supervise_provider_process(&mut child, provider_group)?;
    lock.set_len(0)?;
    unlock(&lock);
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("provider exited with {status}")))
    }
}

#[cfg(not(unix))]
pub fn run_process_host(_lock_file: &Path, _command: &[OsString]) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "provider process hosting requires Unix",
    ))
}

#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;

    use tempfile::tempdir;
    use tokio::process::Command;

    use super::*;

    #[tokio::test]
    async fn free_stale_lock_is_cleared_without_trusting_its_pid() {
        let directory = tempdir().expect("temporary directory");
        let lock_file = directory.path().join("provider.process.lock");
        std::fs::write(&lock_file, "2\n").expect("write stale lock");

        assert!(!reap_stale_process_host(&lock_file).await.expect("reap"));
        assert_eq!(std::fs::read(&lock_file).expect("read lock"), b"");
    }

    #[tokio::test]
    async fn held_lock_authorizes_reaping_the_exact_supervisor_group() {
        let directory = tempdir().expect("temporary directory");
        let lock_file = directory.path().join("provider.process.lock");
        let descendant_pid_file = directory.path().join("unused.pid");
        let mut command = Command::new(std::env::current_exe().expect("current test executable"));
        command
            .args([
                "--exact",
                "process_host::tests::process_host_subprocess",
                "--ignored",
                "--nocapture",
            ])
            .env("INLINE_PROCESS_HOST_TEST_LOCK", &lock_file)
            .env("INLINE_PROCESS_HOST_TEST_PID", &descendant_pid_file)
            .env("INLINE_PROCESS_HOST_TEST_MODE", "stale")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command.as_std_mut().process_group(0);
        let mut supervisor = command.spawn().expect("spawn process-host helper");
        let supervisor_group = i32::try_from(supervisor.id().expect("helper pid")).expect("pid");
        let recorded_group = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let Ok(value) = std::fs::read_to_string(&lock_file)
                    && let Ok(group) = value.trim().parse::<i32>()
                {
                    break group;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("process host should publish ownership");
        assert_eq!(recorded_group, supervisor_group);

        let reaped = reap_stale_process_host(&lock_file).await;
        if reaped.is_err() {
            let _ = signal_process_group(supervisor_group, libc::SIGKILL);
        }
        assert!(reaped.expect("reap held provider lock"));
        let status = tokio::time::timeout(Duration::from_secs(2), supervisor.wait())
            .await
            .expect("provider group should stop")
            .expect("wait for provider");
        assert!(status.success(), "process-host helper failed: {status}");
        assert!(!process_group_exists(supervisor_group).expect("query supervisor group"));
        assert_eq!(std::fs::read(&lock_file).expect("read lock"), b"");
    }

    #[test]
    #[ignore = "subprocess helper for the process-host integration test"]
    fn process_host_subprocess() {
        let Some(lock_file) = std::env::var_os("INLINE_PROCESS_HOST_TEST_LOCK") else {
            return;
        };
        let descendant_pid =
            std::env::var_os("INLINE_PROCESS_HOST_TEST_PID").expect("descendant pid path");
        let mode = std::env::var("INLINE_PROCESS_HOST_TEST_MODE").expect("test mode");
        let command = if mode == "stale" {
            vec![OsString::from("/bin/sleep"), OsString::from("30")]
        } else {
            vec![
                OsString::from("/bin/sh"),
                OsString::from("-c"),
                OsString::from("sleep 30 & printf '%s\\n' \"$!\" > \"$1\""),
                OsString::from("inline-process-host-test"),
                descendant_pid,
            ]
        };
        let result = run_process_host(Path::new(&lock_file), &command);
        if mode == "stale" {
            assert!(result.is_err(), "terminated provider should report failure");
        } else {
            result.expect("supervise provider stand-in");
        }
    }

    #[tokio::test]
    async fn supervisor_alone_holds_the_lock_and_cleans_leaderless_descendants() {
        let directory = tempdir().expect("temporary directory");
        let lock_file = directory.path().join("provider.process.lock");
        let descendant_pid_file = directory.path().join("descendant.pid");
        let mut command = Command::new(std::env::current_exe().expect("current test executable"));
        command
            .args([
                "--exact",
                "process_host::tests::process_host_subprocess",
                "--ignored",
                "--nocapture",
            ])
            .env("INLINE_PROCESS_HOST_TEST_LOCK", &lock_file)
            .env("INLINE_PROCESS_HOST_TEST_PID", &descendant_pid_file)
            .env("INLINE_PROCESS_HOST_TEST_MODE", "leaderless")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command.as_std_mut().process_group(0);
        let mut supervisor = command.spawn().expect("spawn process-host helper");
        let supervisor_group = i32::try_from(supervisor.id().expect("helper pid")).expect("pid");
        let status = match tokio::time::timeout(Duration::from_secs(5), supervisor.wait()).await {
            Ok(result) => result.expect("wait for process-host helper"),
            Err(_) => {
                let _ = signal_process_group(supervisor_group, libc::SIGKILL);
                let _ = supervisor.wait().await;
                panic!("process-host helper timed out");
            }
        };
        assert!(status.success(), "process-host helper failed: {status}");

        let descendant_pid = std::fs::read_to_string(&descendant_pid_file)
            .expect("read descendant pid")
            .trim()
            .parse::<i32>()
            .expect("parse descendant pid");
        let result = unsafe { libc::kill(descendant_pid, 0) };
        assert_eq!(result, -1, "leaderless provider descendant survived");
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
        assert_eq!(std::fs::read(&lock_file).expect("read lock"), b"");
    }
}
