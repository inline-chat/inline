use super::*;
pub(super) fn current_target() -> &'static str {
    if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "aarch64-apple-darwin"
        } else if cfg!(target_arch = "x86_64") {
            "x86_64-apple-darwin"
        } else {
            "unknown"
        }
    } else if cfg!(target_os = "linux") {
        if cfg!(target_arch = "aarch64") {
            if cfg!(target_env = "musl") {
                "aarch64-unknown-linux-musl"
            } else if cfg!(target_env = "gnu") {
                "aarch64-unknown-linux-gnu"
            } else {
                "unknown"
            }
        } else if cfg!(target_arch = "x86_64") {
            if cfg!(target_env = "musl") {
                "x86_64-unknown-linux-musl"
            } else if cfg!(target_env = "gnu") {
                "x86_64-unknown-linux-gnu"
            } else {
                "unknown"
            }
        } else {
            "unknown"
        }
    } else {
        "unknown"
    }
}

pub(super) fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub(super) async fn download_file(target: &UpdateTarget, path: &Path) -> Result<(), UpdateError> {
    if target
        .size
        .is_some_and(|size| size > MAX_UPDATE_DOWNLOAD_BYTES)
    {
        return Err(UpdateError::DownloadTooLarge);
    }
    let client = client_info::http_client_builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::limited(5))
        .timeout(Duration::from_secs(120))
        .build()?;
    download_with_client(&client, target, path).await
}

async fn download_with_client(
    client: &reqwest::Client,
    target: &UpdateTarget,
    path: &Path,
) -> Result<(), UpdateError> {
    if target
        .size
        .is_some_and(|size| size > MAX_UPDATE_DOWNLOAD_BYTES)
    {
        return Err(UpdateError::DownloadTooLarge);
    }
    let mut response = client.get(&target.url).send().await?.error_for_status()?;
    if let Some(actual) = response.content_length() {
        if actual > MAX_UPDATE_DOWNLOAD_BYTES {
            return Err(UpdateError::DownloadTooLarge);
        }
        if let Some(expected) = target.size.filter(|size| *size != actual) {
            return Err(UpdateError::SizeMismatch { expected, actual });
        }
    }
    let mut file = tokio::fs::File::create(path).await?;
    let mut hasher = Sha256::new();
    let mut actual_size = 0u64;
    while let Some(chunk) = response.chunk().await? {
        actual_size = actual_size.saturating_add(chunk.len() as u64);
        if actual_size > MAX_UPDATE_DOWNLOAD_BYTES {
            return Err(UpdateError::DownloadTooLarge);
        }
        if let Some(expected) = target.size.filter(|size| actual_size > *size) {
            return Err(UpdateError::SizeMismatch {
                expected,
                actual: actual_size,
            });
        }
        file.write_all(&chunk).await?;
        hasher.update(&chunk);
    }
    file.flush().await?;
    if let Some(expected) = target.size.filter(|size| *size != actual_size) {
        return Err(UpdateError::SizeMismatch {
            expected,
            actual: actual_size,
        });
    }
    let actual = bytes_to_hex(&hasher.finalize());
    let expected = target.sha256.trim();
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(UpdateError::ChecksumMismatch {
            expected: expected.to_string(),
            actual,
        });
    }
    Ok(())
}

pub(super) fn create_temp_dir() -> Result<tempfile::TempDir, io::Error> {
    let mut builder = tempfile::Builder::new();
    builder.prefix("inline-update-");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(fs::Permissions::from_mode(0o700));
    }
    builder.tempdir()
}

pub(super) fn validate_binary(path: &Path) -> Result<(), UpdateError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(()),
        Ok(_) => Err(UpdateError::InvalidBinary),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Err(UpdateError::MissingBinary),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn bytes_to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("{:02x}", byte));
    }
    out
}

pub(super) fn extract_archive(archive_path: &Path, output_dir: &Path) -> Result<(), UpdateError> {
    let mut archive = Archive::new(GzDecoder::new(File::open(archive_path)?));
    let mut found = false;
    for item in archive.entries()? {
        let mut entry = item?;
        let path = entry.path()?;
        if found
            || !matches!(path.to_str(), Some("inline" | "./inline"))
            || !entry.header().entry_type().is_file()
            || entry.size() == 0
            || entry.size() > 200 * 1024 * 1024
        {
            return Err(UpdateError::Verification("archive"));
        }
        let mut output = File::create(output_dir.join("inline"))?;
        let count = io::copy(
            &mut std::io::Read::by_ref(&mut entry).take(200 * 1024 * 1024 + 1),
            &mut output,
        )?;
        if count == 0 || count > 200 * 1024 * 1024 {
            return Err(UpdateError::Verification("archive_size"));
        }
        output.sync_all()?;
        found = true;
    }
    if !found {
        return Err(UpdateError::MissingBinary);
    }
    Ok(())
}

pub(super) fn stage_binary(
    extracted_binary: &Path,
    stage_dir: &Path,
) -> Result<PathBuf, UpdateError> {
    let staged_path = stage_dir.join("inline.new");
    fs::copy(extracted_binary, &staged_path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&staged_path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&staged_path, perms)?;
    }
    Ok(staged_path)
}

pub(super) fn copy_binary_atomically(
    staged_path: &Path,
    install_path: &Path,
) -> Result<(), io::Error> {
    let parent = install_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "install path has no parent directory",
        )
    })?;
    let mut replacement = tempfile::Builder::new()
        .prefix(".inline-update-")
        .tempfile_in(parent)?;
    let mut source = File::open(staged_path)?;
    io::copy(&mut source, replacement.as_file_mut())?;
    replacement
        .as_file()
        .set_permissions(source.metadata()?.permissions())?;
    replacement.as_file().sync_all()?;
    replacement
        .persist(install_path)
        .map_err(|error| error.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;

    fn target(url: String, body: &[u8], size: Option<u64>) -> UpdateTarget {
        UpdateTarget {
            url,
            sha256: bytes_to_hex(&Sha256::digest(body)),
            size,
        }
    }

    async fn read_request(stream: &mut tokio::net::TcpStream) {
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).await.unwrap();
                request.push(byte[0]);
                assert!(request.len() < 16 * 1024);
            }
            assert!(request.starts_with(b"GET /archive HTTP/1.1\r\n"));
        })
        .await
        .expect("complete HTTP request");
    }

    async fn serve(response: Vec<u8>) -> (String, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/archive", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            stream.write_all(&response).await.unwrap();
            stream.shutdown().await.unwrap();
        });
        (url, task)
    }

    fn response(body: &[u8]) -> Vec<u8> {
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(body);
        response
    }

    async fn test_download(target: &UpdateTarget, path: &Path) -> Result<(), UpdateError> {
        download_with_client(
            &reqwest::Client::builder().no_proxy().build().unwrap(),
            target,
            path,
        )
        .await
    }

    #[tokio::test]
    async fn archive_is_written_before_the_server_finishes_and_hashes_all_chunks() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("archive");
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/archive", listener.local_addr().unwrap());
        let body = vec![b'x'; 64 * 1024];
        let target = target(url, &body, Some(body.len() as u64));
        let (first_sent, first_received) = oneshot::channel();
        let (continue_send, continue_receive) = oneshot::channel();
        let server_body = body.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                )
                .await
                .unwrap();
            stream.write_all(b"8000\r\n").await.unwrap();
            stream.write_all(&server_body[..32 * 1024]).await.unwrap();
            stream.write_all(b"\r\n").await.unwrap();
            // The second chunk is held until the test sees the first on disk.
            first_sent.send(()).unwrap();
            continue_receive.await.unwrap();
            stream.write_all(b"8000\r\n").await.unwrap();
            stream.write_all(&server_body[32 * 1024..]).await.unwrap();
            stream.write_all(b"\r\n0\r\n\r\n").await.unwrap();
        });
        let download_path = path.clone();
        let download = tokio::spawn(async move { test_download(&target, &download_path).await });
        tokio::time::timeout(Duration::from_secs(5), first_received)
            .await
            .expect("first response chunk")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > 0) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("first chunk should reach disk before response completes");
        assert!(!download.is_finished());
        continue_send.send(()).unwrap();
        download.await.unwrap().unwrap();
        server.await.unwrap();
        assert_eq!(fs::read(path).unwrap(), body);
    }

    #[tokio::test]
    async fn downloads_reject_bad_hash_size_and_truncated_responses() {
        let root = tempfile::tempdir().unwrap();
        let body = b"binary fixture";
        let (url, server) = serve(response(body)).await;
        let mut bad_hash = target(url, body, None);
        bad_hash.sha256 = "0".repeat(64);
        assert!(matches!(
            test_download(&bad_hash, &root.path().join("bad-hash")).await,
            Err(UpdateError::ChecksumMismatch { .. })
        ));
        server.await.unwrap();

        let (url, server) = serve(response(body)).await;
        let bad_size = target(url, body, Some(1));
        let path = root.path().join("bad-size");
        assert!(matches!(
            test_download(&bad_size, &path).await,
            Err(UpdateError::SizeMismatch { .. })
        ));
        assert!(!path.exists());
        server.await.unwrap();

        let (url, server) = serve(
            b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort".to_vec(),
        )
        .await;
        let truncated = target(url, body, None);
        assert!(matches!(
            test_download(&truncated, &root.path().join("truncated")).await,
            Err(UpdateError::Http(_))
        ));
        server.await.unwrap();

        let oversize = target(
            "http://127.0.0.1:9/archive".into(),
            body,
            Some(MAX_UPDATE_DOWNLOAD_BYTES + 1),
        );
        let path = root.path().join("oversize");
        assert!(matches!(
            test_download(&oversize, &path).await,
            Err(UpdateError::DownloadTooLarge)
        ));
        assert!(!path.exists());

        let (url, server) = serve(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                MAX_UPDATE_DOWNLOAD_BYTES + 1
            )
            .into_bytes(),
        )
        .await;
        let oversize_response = target(url, body, None);
        let path = root.path().join("oversize-response");
        assert!(matches!(
            test_download(&oversize_response, &path).await,
            Err(UpdateError::DownloadTooLarge)
        ));
        assert!(!path.exists());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn downloads_accept_manifests_without_size_and_uppercase_checksums() {
        let root = tempfile::tempdir().unwrap();
        let body = b"binary fixture";
        let (url, server) = serve(response(body)).await;
        let mut target = target(url, body, None);
        target.sha256 = target.sha256.to_uppercase();
        let path = root.path().join("archive");
        test_download(&target, &path).await.unwrap();
        server.await.unwrap();
        assert_eq!(fs::read(path).unwrap(), body);
    }

    #[tokio::test]
    async fn chunked_downloads_enforce_optional_manifest_size() {
        for expected in [1, 20] {
            let root = tempfile::tempdir().unwrap();
            let (url, server) = serve(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nbinary\r\n0\r\n\r\n"
                    .to_vec(),
            )
            .await;
            let target = target(url, b"binary", Some(expected));
            assert!(matches!(
                test_download(&target, &root.path().join("archive")).await,
                Err(UpdateError::SizeMismatch { .. })
            ));
            server.await.unwrap();
        }
    }

    #[test]
    fn atomic_copy_replaces_the_binary_without_modifying_old_open_handles() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source");
        let destination = root.path().join("inline");
        fs::write(&source, b"new complete binary").unwrap();
        fs::write(&destination, b"old complete binary").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut previous_handle = File::open(&destination).unwrap();
        copy_binary_atomically(&source, &destination).unwrap();
        assert_eq!(fs::read(&destination).unwrap(), b"new complete binary");
        let mut old = String::new();
        previous_handle.read_to_string(&mut old).unwrap();
        assert_eq!(old, "old complete binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
                0o755
            );
        }
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
    }

    #[test]
    fn failed_atomic_copy_keeps_the_existing_install_and_leaves_no_sibling_file() {
        let root = tempfile::tempdir().unwrap();
        let destination = root.path().join("inline");
        fs::write(&destination, b"working binary").unwrap();
        assert!(copy_binary_atomically(&root.path().join("missing"), &destination).is_err());
        assert_eq!(fs::read(&destination).unwrap(), b"working binary");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);

        let directory = root.path().join("directory");
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("keep"), b"untouched").unwrap();
        assert!(copy_binary_atomically(&destination, &directory).is_err());
        assert_eq!(fs::read(directory.join("keep")).unwrap(), b"untouched");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
    }

    #[test]
    fn bundle_binary_must_be_a_regular_file() {
        let root = tempfile::tempdir().unwrap();
        assert!(matches!(
            validate_binary(&root.path().join("missing")),
            Err(UpdateError::MissingBinary)
        ));
        assert!(matches!(
            validate_binary(root.path()),
            Err(UpdateError::InvalidBinary)
        ));
        let regular = root.path().join("inline");
        fs::write(&regular, b"binary").unwrap();
        validate_binary(&regular).unwrap();
        #[cfg(unix)]
        {
            let link = root.path().join("link");
            std::os::unix::fs::symlink(&regular, &link).unwrap();
            assert!(matches!(
                validate_binary(&link),
                Err(UpdateError::InvalidBinary)
            ));
        }
    }
    #[test]
    fn archive_rejects_links_duplicate_entries_and_unexpected_paths() {
        for (names, kind, size) in [
            (vec!["inline"], tar::EntryType::Symlink, 0),
            (vec!["inline", "inline"], tar::EntryType::Regular, 3),
            (vec!["other"], tar::EntryType::Regular, 3),
            (vec!["inline"], tar::EntryType::Regular, 201 * 1024 * 1024),
        ] {
            let root = tempfile::tempdir().unwrap();
            let path = root.path().join("archive.tar.gz");
            let encoder = flate2::write::GzEncoder::new(
                File::create(&path).unwrap(),
                flate2::Compression::fast(),
            );
            let mut tar = tar::Builder::new(encoder);
            for name in names {
                let mut header = tar::Header::new_gnu();
                header.set_path(name).unwrap();
                header.set_size(size);
                header.set_entry_type(kind);
                header.set_mode(0o755);
                header.set_cksum();
                // For the oversized-entry case a truncated header is sufficient;
                // the extractor must reject the bound before allocating/reading it.
                tar.append(&header, &b"abc"[..size.min(3) as usize])
                    .unwrap();
            }
            tar.into_inner().unwrap().finish().unwrap();
            let out = root.path().join("out");
            fs::create_dir(&out).unwrap();
            assert!(extract_archive(&path, &out).is_err());
            assert!(!root.path().join("other").exists());
        }
    }
}
