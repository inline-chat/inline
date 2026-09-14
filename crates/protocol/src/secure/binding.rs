//! Telegram-compatible temporary authorization-key binding.

use super::{InvalidEncryptedRecord, aes_ige_encrypt, auth_key_id};
use sha1::{Digest, Sha1};

const BIND_AUTH_KEY_INNER: u32 = 0x75a3_f765;
const BIND_TEMP_AUTH_KEY: u32 = 0xcdd4_2a05;

fn sha1(parts: &[&[u8]]) -> [u8; 20] {
    let mut digest = Sha1::new();
    for part in parts {
        digest.update(part);
    }
    digest.finalize().into()
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    let mut output = Vec::with_capacity(parts.iter().map(|part| part.len()).sum());
    for part in parts {
        output.extend_from_slice(part);
    }
    output
}

fn key_id_long(key: &[u8]) -> Result<i64, InvalidEncryptedRecord> {
    Ok(i64::from_le_bytes(auth_key_id(key)?))
}

fn encode_tl_bytes(value: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if value.len() > 0x00ff_ffff {
        return Err(InvalidEncryptedRecord);
    }
    let mut output = Vec::new();
    if value.len() < 254 {
        output.push(value.len() as u8);
    } else {
        output.extend_from_slice(&[
            254,
            value.len() as u8,
            (value.len() >> 8) as u8,
            (value.len() >> 16) as u8,
        ]);
    }
    output.extend_from_slice(value);
    output.resize(output.len().next_multiple_of(4), 0);
    Ok(output)
}

fn derive_v1_aes(
    auth_key: &[u8],
    message_key: &[u8],
) -> Result<([u8; 32], [u8; 32]), InvalidEncryptedRecord> {
    if auth_key.len() != 256 || message_key.len() != 16 {
        return Err(InvalidEncryptedRecord);
    }
    let a = sha1(&[message_key, &auth_key[..32]]);
    let b = sha1(&[&auth_key[32..48], message_key, &auth_key[48..64]]);
    let c = sha1(&[&auth_key[64..96], message_key]);
    let d = sha1(&[message_key, &auth_key[96..128]]);
    let key = concat(&[&a[..8], &b[8..20], &c[4..16]]);
    let iv = concat(&[&a[8..20], &b[..8], &c[16..20], &d[..8]]);
    Ok((
        key.try_into().map_err(|_| InvalidEncryptedRecord)?,
        iv.try_into().map_err(|_| InvalidEncryptedRecord)?,
    ))
}

/// Creates the exact isolated encrypted binding proof.
#[allow(clippy::too_many_arguments)]
pub fn create_temporary_key_binding_proof(
    permanent_auth_key: &[u8],
    temporary_auth_key: &[u8],
    temporary_session_id: i64,
    message_id: i64,
    nonce: i64,
    expires_at: i32,
    random_int128: &[u8],
    random_padding: &[u8],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if random_int128.len() != 16 || random_padding.len() != 8 {
        return Err(InvalidEncryptedRecord);
    }
    let inner = concat(&[
        &BIND_AUTH_KEY_INNER.to_le_bytes(),
        &nonce.to_le_bytes(),
        &key_id_long(temporary_auth_key)?.to_le_bytes(),
        &key_id_long(permanent_auth_key)?.to_le_bytes(),
        &temporary_session_id.to_le_bytes(),
        &expires_at.to_le_bytes(),
    ]);
    let plaintext_without_padding = concat(&[
        random_int128,
        &message_id.to_le_bytes(),
        &0_i32.to_le_bytes(),
        &(inner.len() as i32).to_le_bytes(),
        &inner,
    ]);
    let message_key = sha1(&[&plaintext_without_padding])[4..20].to_vec();
    let (key, iv) = derive_v1_aes(permanent_auth_key, &message_key)?;
    Ok(concat(&[
        &auth_key_id(permanent_auth_key)?,
        &message_key,
        &aes_ige_encrypt(
            &concat(&[&plaintext_without_padding, random_padding]),
            &key,
            &iv,
        )?,
    ]))
}

/// Encodes `auth.bindTempAuthKey` around a 104-byte binding proof.
pub fn encode_bind_temporary_auth_key(
    permanent_auth_key_id: i64,
    nonce: i64,
    expires_at: i32,
    proof: &[u8],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if proof.len() != 104 {
        return Err(InvalidEncryptedRecord);
    }
    Ok(concat(&[
        &BIND_TEMP_AUTH_KEY.to_le_bytes(),
        &permanent_auth_key_id.to_le_bytes(),
        &nonce.to_le_bytes(),
        &expires_at.to_le_bytes(),
        &encode_tl_bytes(proof)?,
    ]))
}
