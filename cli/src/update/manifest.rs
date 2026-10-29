use std::collections::BTreeMap;

use base64::{Engine, engine::general_purpose::STANDARD};
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::{Deserialize, Serialize};

use super::{UpdateChannel, UpdateError};

pub const DOMAIN: &[u8] = b"inline-cli-channel-v1\0";
pub const MAX_MANIFEST_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub format_version: u32,
    pub channel: UpdateChannel,
    pub generation: u64,
    pub version: String,
    pub source_sha: String,
    pub bridge_schema_version: u32,
    pub minimum_reader_schema_version: u32,
    pub supervisor_protocol: u32,
    #[serde(default)]
    pub required_baseline: Option<Box<Release>>,
    pub targets: BTreeMap<String, Target>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Deserialize)]
struct Envelope {
    payload: String,
    signatures: Vec<Signature>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Signature {
    key_id: String,
    signature: String,
}

pub fn pinned_keys() -> BTreeMap<String, String> {
    serde_json::from_str(include_str!("../../release-keys.json")).expect("embedded release keys")
}

pub fn verify(bytes: &[u8], channel: UpdateChannel) -> Result<Release, UpdateError> {
    verify_with_keys(bytes, channel, &pinned_keys())
}

pub fn verify_with_keys(
    bytes: &[u8],
    channel: UpdateChannel,
    keys: &BTreeMap<String, String>,
) -> Result<Release, UpdateError> {
    if bytes.len() > MAX_MANIFEST_BYTES {
        return Err(UpdateError::Verification("manifest_size"));
    }
    let envelope: Envelope = serde_json::from_slice(bytes)?;
    let payload = STANDARD
        .decode(&envelope.payload)
        .map_err(|_| UpdateError::Verification("signature"))?;
    let mut signed = DOMAIN.to_vec();
    signed.extend_from_slice(&payload);
    let authenticated = envelope.signatures.iter().take(4).any(|entry| {
        let Some(key) = keys
            .get(&entry.key_id)
            .and_then(|value| STANDARD.decode(value).ok())
        else {
            return false;
        };
        let Ok(signature) = STANDARD.decode(&entry.signature) else {
            return false;
        };
        UnparsedPublicKey::new(&ED25519, key)
            .verify(&signed, &signature)
            .is_ok()
    });
    if !authenticated {
        return Err(UpdateError::Verification("signature"));
    }
    let release: Release = serde_json::from_slice(&payload)?;
    validate(&release, channel, 0)?;
    Ok(release)
}

fn validate(release: &Release, channel: UpdateChannel, depth: usize) -> Result<(), UpdateError> {
    let version = semver::Version::parse(&release.version)?;
    if release.format_version != 1
        || release.channel != channel
        || release.supervisor_protocol != 1
        || depth > 4
        || release.generation == 0
        || release.source_sha.len() != 40
        || !release
            .source_sha
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
        || release.minimum_reader_schema_version > release.bridge_schema_version
        || (channel == UpdateChannel::Stable && !version.pre.is_empty())
    {
        return Err(UpdateError::Verification("manifest_contract"));
    }
    for target in release.targets.values() {
        if target.sha256.len() != 64
            || !target.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
            || target.size == 0
            || target.size > super::MAX_UPDATE_DOWNLOAD_BYTES
            || url::Url::parse(&target.url).map_or(true, |url| {
                url.scheme() != "https"
                    || url.host_str().is_none()
                    || !url.username().is_empty()
                    || url.password().is_some()
            })
        {
            return Err(UpdateError::Verification("target_contract"));
        }
    }
    if let Some(baseline) = &release.required_baseline {
        if semver::Version::parse(&baseline.version)?
            .cmp_precedence(&version)
            .is_ge()
        {
            return Err(UpdateError::Verification("baseline_order"));
        }
        validate(baseline, channel, depth + 1)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::{
        rand::SystemRandom,
        signature::{Ed25519KeyPair, KeyPair},
    };

    pub fn signed_release(channel: UpdateChannel) -> (Vec<u8>, BTreeMap<String, String>) {
        let key = Ed25519KeyPair::from_pkcs8(
            Ed25519KeyPair::generate_pkcs8(&SystemRandom::new())
                .unwrap()
                .as_ref(),
        )
        .unwrap();
        let release = Release {
            format_version: 1,
            channel,
            generation: 1,
            version: "1.2.3-alpha.1".into(),
            source_sha: "a".repeat(40),
            bridge_schema_version: 30,
            minimum_reader_schema_version: 30,
            supervisor_protocol: 1,
            required_baseline: None,
            targets: BTreeMap::new(),
        };
        let payload = serde_json::to_vec(&release).unwrap();
        let mut message = DOMAIN.to_vec();
        message.extend_from_slice(&payload);
        let bytes = serde_json::to_vec(&serde_json::json!({"payload":STANDARD.encode(payload),"signatures":[{"keyId":"test","signature":STANDARD.encode(key.sign(&message).as_ref())}]})).unwrap();
        (
            bytes,
            BTreeMap::from([("test".into(), STANDARD.encode(key.public_key().as_ref()))]),
        )
    }

    #[test]
    fn updater_verifies_the_shared_publisher_and_cryptokit_vector() {
        let vector: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/signed-channel.json")).unwrap();
        let keys: BTreeMap<String, String> =
            serde_json::from_value(vector["keys"].clone()).unwrap();
        let bytes = serde_json::to_vec(&vector["envelope"]).unwrap();
        let release = verify_with_keys(&bytes, UpdateChannel::Alpha, &keys).unwrap();
        assert_eq!(serde_json::to_value(release).unwrap(), vector["release"]);
        assert!(verify_with_keys(&bytes, UpdateChannel::Stable, &keys).is_err());
        assert!(
            verify(&bytes, UpdateChannel::Alpha).is_err(),
            "test roots must never be trusted by production"
        );
    }

    #[test]
    fn authenticates_exact_payload_and_channel_before_use() {
        let (bytes, keys) = signed_release(UpdateChannel::Alpha);
        assert!(verify_with_keys(&bytes, UpdateChannel::Alpha, &keys).is_ok());
        assert!(verify_with_keys(&bytes, UpdateChannel::Stable, &keys).is_err());
        assert!(verify_with_keys(&bytes, UpdateChannel::Alpha, &BTreeMap::new()).is_err());
        let mut changed: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        changed["payload"] = STANDARD.encode(b"{}").into();
        assert!(
            verify_with_keys(
                &serde_json::to_vec(&changed).unwrap(),
                UpdateChannel::Alpha,
                &keys
            )
            .is_err()
        );
    }
}
