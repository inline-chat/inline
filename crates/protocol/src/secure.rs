//! Portable cryptographic and wire primitives for Inline Protocol v1.

use aes::Aes256;
use cipher::{BlockDecrypt, BlockEncrypt, KeyInit, generic_array::GenericArray};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

/// Authorization-key handshake cryptography.
pub mod handshake;

/// Maximum accepted carrier packet and decrypted body size.
pub const MAX_PACKET_BYTES: usize = 16 * 1024 * 1024;

/// `inline.result` TL constructor.
pub const INLINE_RESULT_CONSTRUCTOR: u32 = 0xac3ddc54;
/// `inline.update` TL constructor.
pub const INLINE_UPDATE_CONSTRUCTOR: u32 = 0xdc412c98;
/// `inline.invoke` TL constructor.
pub const INLINE_INVOKE_CONSTRUCTOR: u32 = 0xeb7d4aa6;
/// Realtime V3 application layer.
pub const INLINE_REALTIME_LAYER: i32 = 3;

/// A decoded Inline-specific TL application constructor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InlineApplicationObject {
    /// Content-related application invocation.
    Invoke {
        /// Declared Realtime application layer.
        layer: i32,
        /// Exact protobuf payload bytes.
        payload: Vec<u8>,
    },
    /// RPC result payload.
    Result(Vec<u8>),
    /// Unsolicited update payload.
    Update(Vec<u8>),
}

/// Direction used by the MTProto v2 record KDF.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    /// Client to server (`x = 0`).
    ClientToServer,
    /// Server to client (`x = 8`).
    ServerToClient,
}

/// Validated decrypted record fields.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordFields {
    /// Active server salt.
    pub server_salt: i64,
    /// Logical session identifier.
    pub session_id: i64,
    /// MTProto message identifier.
    pub message_id: i64,
    /// MTProto sequence number.
    pub sequence_number: i32,
    /// Exact authenticated TL body bytes.
    pub body: Vec<u8>,
}

/// Uniform externally visible encrypted-record failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidEncryptedRecord;

impl std::fmt::Display for InvalidEncryptedRecord {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("invalid Inline Protocol encrypted record")
    }
}

impl std::error::Error for InvalidEncryptedRecord {}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    let length = parts.iter().map(|part| part.len()).sum();
    let mut bytes = Vec::with_capacity(length);
    for part in parts {
        bytes.extend_from_slice(part);
    }
    bytes
}

fn encode_tl_bytes(value: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if value.len() > MAX_PACKET_BYTES || value.len() > 0x00ff_ffff {
        return Err(InvalidEncryptedRecord);
    }
    let mut output = Vec::with_capacity(value.len() + 4);
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

fn decode_tl_bytes(bytes: &[u8]) -> Result<(&[u8], usize), InvalidEncryptedRecord> {
    let first = *bytes.first().ok_or(InvalidEncryptedRecord)?;
    let (length, header_length) = if first < 254 {
        (usize::from(first), 1_usize)
    } else if first == 254 && bytes.len() >= 4 {
        (
            usize::from(bytes[1]) | usize::from(bytes[2]) << 8 | usize::from(bytes[3]) << 16,
            4_usize,
        )
    } else {
        return Err(InvalidEncryptedRecord);
    };
    if length > MAX_PACKET_BYTES {
        return Err(InvalidEncryptedRecord);
    }
    let encoded_length = header_length
        .checked_add(length)
        .ok_or(InvalidEncryptedRecord)?;
    let total_length = encoded_length.next_multiple_of(4);
    if bytes.len() < total_length
        || bytes[encoded_length..total_length]
            .iter()
            .any(|byte| *byte != 0)
    {
        return Err(InvalidEncryptedRecord);
    }
    Ok((&bytes[header_length..header_length + length], total_length))
}

/// Encodes `inline.invoke` around exact protobuf payload bytes.
pub fn encode_inline_invoke(payload: &[u8], layer: i32) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    Ok(concat(&[
        &INLINE_INVOKE_CONSTRUCTOR.to_le_bytes(),
        &layer.to_le_bytes(),
        &encode_tl_bytes(payload)?,
    ]))
}

/// Encodes `inline.result` around exact protobuf payload bytes.
pub fn encode_inline_result(payload: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    Ok(concat(&[
        &INLINE_RESULT_CONSTRUCTOR.to_le_bytes(),
        &encode_tl_bytes(payload)?,
    ]))
}

/// Encodes `inline.update` around exact protobuf payload bytes.
pub fn encode_inline_update(payload: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    Ok(concat(&[
        &INLINE_UPDATE_CONSTRUCTOR.to_le_bytes(),
        &encode_tl_bytes(payload)?,
    ]))
}

/// Decodes exactly one Inline-specific TL application constructor.
pub fn decode_inline_application_object(
    bytes: &[u8],
) -> Result<InlineApplicationObject, InvalidEncryptedRecord> {
    if bytes.len() < 8 {
        return Err(InvalidEncryptedRecord);
    }
    let constructor =
        u32::from_le_bytes(bytes[..4].try_into().map_err(|_| InvalidEncryptedRecord)?);
    if constructor == INLINE_INVOKE_CONSTRUCTOR {
        let layer = i32::from_le_bytes(bytes[4..8].try_into().map_err(|_| InvalidEncryptedRecord)?);
        let (payload, consumed) = decode_tl_bytes(&bytes[8..])?;
        if 8 + consumed != bytes.len() {
            return Err(InvalidEncryptedRecord);
        }
        return Ok(InlineApplicationObject::Invoke {
            layer,
            payload: payload.to_vec(),
        });
    }
    let (payload, consumed) = decode_tl_bytes(&bytes[4..])?;
    if 4 + consumed != bytes.len() {
        return Err(InvalidEncryptedRecord);
    }
    match constructor {
        INLINE_RESULT_CONSTRUCTOR => Ok(InlineApplicationObject::Result(payload.to_vec())),
        INLINE_UPDATE_CONSTRUCTOR => Ok(InlineApplicationObject::Update(payload.to_vec())),
        _ => Err(InvalidEncryptedRecord),
    }
}

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

/// Computes the serialized little-endian auth-key identifier bytes.
pub fn auth_key_id(auth_key: &[u8]) -> Result<[u8; 8], InvalidEncryptedRecord> {
    if auth_key.len() != 256 {
        return Err(InvalidEncryptedRecord);
    }
    let digest = Sha1::digest(auth_key);
    Ok(digest[12..20].try_into().expect("fixed SHA-1 slice"))
}

/// Computes MTProto v2's message key over the exact full plaintext.
pub fn compute_v2_msg_key(
    auth_key: &[u8],
    plaintext: &[u8],
    direction: Direction,
) -> Result<[u8; 16], InvalidEncryptedRecord> {
    if auth_key.len() != 256 {
        return Err(InvalidEncryptedRecord);
    }
    let x = if direction == Direction::ClientToServer {
        0
    } else {
        8
    };
    Ok(sha256(&[&auth_key[88 + x..120 + x], plaintext])[8..24]
        .try_into()
        .expect("fixed SHA-256 slice"))
}

/// Derives the MTProto v2 AES-256 key and IGE IV.
pub fn derive_v2_aes(
    auth_key: &[u8],
    msg_key: &[u8],
    direction: Direction,
) -> Result<([u8; 32], [u8; 32]), InvalidEncryptedRecord> {
    if auth_key.len() != 256 || msg_key.len() != 16 {
        return Err(InvalidEncryptedRecord);
    }
    let x = if direction == Direction::ClientToServer {
        0
    } else {
        8
    };
    let a = sha256(&[msg_key, &auth_key[x..36 + x]]);
    let b = sha256(&[&auth_key[40 + x..76 + x], msg_key]);
    let key = concat(&[&a[..8], &b[8..24], &a[24..32]]);
    let iv = concat(&[&b[..8], &a[8..24], &b[24..32]]);
    Ok((
        key.try_into().expect("32-byte AES key"),
        iv.try_into().expect("32-byte IGE IV"),
    ))
}

fn xor_block(left: &[u8], right: &[u8]) -> [u8; 16] {
    std::array::from_fn(|index| left[index] ^ right[index])
}

/// Encrypts block-aligned bytes with AES-256-IGE and no padding.
pub fn aes_ige_encrypt(
    plaintext: &[u8],
    key: &[u8; 32],
    iv: &[u8; 32],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if plaintext.len() % 16 != 0 {
        return Err(InvalidEncryptedRecord);
    }
    let cipher = Aes256::new_from_slice(key).map_err(|_| InvalidEncryptedRecord)?;
    let mut previous_cipher = <[u8; 16]>::try_from(&iv[..16]).expect("fixed IV half");
    let mut previous_plain = <[u8; 16]>::try_from(&iv[16..]).expect("fixed IV half");
    let mut output = Vec::with_capacity(plaintext.len());
    for plain in plaintext.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(&xor_block(plain, &previous_cipher));
        cipher.encrypt_block(&mut block);
        let encrypted = xor_block(&block, &previous_plain);
        output.extend_from_slice(&encrypted);
        previous_cipher = encrypted;
        previous_plain.copy_from_slice(plain);
    }
    Ok(output)
}

/// Decrypts block-aligned AES-256-IGE bytes with no padding.
pub fn aes_ige_decrypt(
    ciphertext: &[u8],
    key: &[u8; 32],
    iv: &[u8; 32],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if ciphertext.len() % 16 != 0 {
        return Err(InvalidEncryptedRecord);
    }
    let cipher = Aes256::new_from_slice(key).map_err(|_| InvalidEncryptedRecord)?;
    let mut previous_cipher = <[u8; 16]>::try_from(&iv[..16]).expect("fixed IV half");
    let mut previous_plain = <[u8; 16]>::try_from(&iv[16..]).expect("fixed IV half");
    let mut output = Vec::with_capacity(ciphertext.len());
    for encrypted in ciphertext.chunks_exact(16) {
        let mixed = xor_block(encrypted, &previous_plain);
        let mut block = GenericArray::clone_from_slice(&mixed);
        cipher.decrypt_block(&mut block);
        let plain = xor_block(&block, &previous_cipher);
        output.extend_from_slice(&plain);
        previous_cipher.copy_from_slice(encrypted);
        previous_plain = plain;
    }
    Ok(output)
}

/// Encrypts a complete MTProto v2 record with caller-supplied CSPRNG padding.
pub fn encrypt_record(
    auth_key: &[u8],
    direction: Direction,
    fields: &RecordFields,
    padding: &[u8],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if fields.body.len() > MAX_PACKET_BYTES
        || fields.body.len() % 4 != 0
        || !(12..=1024).contains(&padding.len())
    {
        return Err(InvalidEncryptedRecord);
    }
    let mut plaintext = Vec::with_capacity(32 + fields.body.len() + padding.len());
    plaintext.extend_from_slice(&fields.server_salt.to_le_bytes());
    plaintext.extend_from_slice(&fields.session_id.to_le_bytes());
    plaintext.extend_from_slice(&fields.message_id.to_le_bytes());
    plaintext.extend_from_slice(&fields.sequence_number.to_le_bytes());
    plaintext.extend_from_slice(&(fields.body.len() as i32).to_le_bytes());
    plaintext.extend_from_slice(&fields.body);
    plaintext.extend_from_slice(padding);
    if plaintext.len() % 16 != 0 {
        return Err(InvalidEncryptedRecord);
    }
    let msg_key = compute_v2_msg_key(auth_key, &plaintext, direction)?;
    let (key, iv) = derive_v2_aes(auth_key, &msg_key, direction)?;
    Ok(concat(&[
        &auth_key_id(auth_key)?,
        &msg_key,
        &aes_ige_encrypt(&plaintext, &key, &iv)?,
    ]))
}

/// Decrypts, authenticates, and structurally validates a complete v2 record.
pub fn decrypt_record(
    record: &[u8],
    auth_key: &[u8],
    direction: Direction,
    expected_session_id: i64,
    valid_server_salts: &BTreeSet<i64>,
    now_seconds: i64,
) -> Result<RecordFields, InvalidEncryptedRecord> {
    if record.len() < 72 || record.len() > MAX_PACKET_BYTES || (record.len() - 24) % 16 != 0 {
        return Err(InvalidEncryptedRecord);
    }
    let msg_key = &record[8..24];
    let (key, iv) = derive_v2_aes(auth_key, msg_key, direction)?;
    let plaintext = aes_ige_decrypt(&record[24..], &key, &iv)?;
    let expected_msg_key = compute_v2_msg_key(auth_key, &plaintext, direction)?;
    let key_id_valid = constant_time_equal(&record[..8], &auth_key_id(auth_key)?);
    let msg_key_valid = constant_time_equal(msg_key, &expected_msg_key);
    if !key_id_valid || !msg_key_valid {
        return Err(InvalidEncryptedRecord);
    }
    let body_length = i32::from_le_bytes(
        plaintext[28..32]
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    );
    if body_length < 0 {
        return Err(InvalidEncryptedRecord);
    }
    let body_length = body_length as usize;
    let padding_length = plaintext
        .len()
        .checked_sub(32 + body_length)
        .ok_or(InvalidEncryptedRecord)?;
    if body_length > MAX_PACKET_BYTES
        || body_length % 4 != 0
        || !(12..=1024).contains(&padding_length)
    {
        return Err(InvalidEncryptedRecord);
    }
    let server_salt = i64::from_le_bytes(
        plaintext[..8]
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    );
    let session_id = i64::from_le_bytes(
        plaintext[8..16]
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    );
    let message_id = i64::from_le_bytes(
        plaintext[16..24]
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    );
    let sequence_number = i32::from_le_bytes(
        plaintext[24..28]
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    );
    let message_seconds = message_id >> 32;
    let valid_direction = match direction {
        Direction::ClientToServer => message_id & 3 == 0 && message_id as u32 != 0,
        Direction::ServerToClient => message_id & 1 == 1,
    };
    if session_id != expected_session_id
        || !valid_server_salts.contains(&server_salt)
        || message_id == 0
        || !valid_direction
        || !(now_seconds - 300..=now_seconds + 30).contains(&message_seconds)
        || sequence_number < 0
    {
        return Err(InvalidEncryptedRecord);
    }
    Ok(RecordFields {
        server_salt,
        session_id,
        message_id,
        sequence_number,
        body: plaintext[32..32 + body_length].to_vec(),
    })
}

/// Encodes one complete abridged transport packet.
pub fn encode_abridged_packet(payload: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if payload.is_empty() || payload.len() > MAX_PACKET_BYTES || payload.len() % 4 != 0 {
        return Err(InvalidEncryptedRecord);
    }
    let words = payload.len() / 4;
    let mut output = Vec::with_capacity(payload.len() + 4);
    if words < 127 {
        output.push(words as u8);
    } else if words <= 0x00ff_ffff {
        output.extend_from_slice(&[0x7f, words as u8, (words >> 8) as u8, (words >> 16) as u8]);
    } else {
        return Err(InvalidEncryptedRecord);
    }
    output.extend_from_slice(payload);
    Ok(output)
}

/// Bounded 1,000-ID-compatible receive window that permits unseen out-of-order IDs.
pub struct ReceiveMessageWindow {
    capacity: usize,
    accepted: BTreeSet<i64>,
}

impl ReceiveMessageWindow {
    /// Creates a receive window with the given positive capacity.
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "receive window capacity must be positive");
        Self {
            capacity,
            accepted: BTreeSet::new(),
        }
    }

    /// Claims a fresh ID, returning false for duplicates and IDs below the retained minimum.
    pub fn claim(&mut self, message_id: i64) -> bool {
        if self.accepted.contains(&message_id) {
            return false;
        }
        if self.accepted.len() >= self.capacity
            && self
                .accepted
                .first()
                .is_some_and(|minimum| message_id < *minimum)
        {
            return false;
        }
        self.accepted.insert(message_id);
        while self.accepted.len() > self.capacity {
            self.accepted.pop_first();
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn matches_frozen_typescript_record_vector() {
        let auth_key: Vec<u8> = (0..=255).collect();
        let fields = RecordFields {
            server_salt: 0x0102030405060708,
            session_id: 0x1112131415161718,
            message_id: (1_700_000_000_i64 << 32) | 4,
            sequence_number: 1,
            body: vec![0xa6, 0x4a, 0x7d, 0xeb, 3, 0, 0, 0],
        };
        let padding: Vec<u8> = (0xa0..=0xb7).collect();
        let record =
            encrypt_record(&auth_key, Direction::ClientToServer, &fields, &padding).unwrap();
        assert_eq!(
            hex(&record),
            "32d1586ea457dfc80b016bab73824ee1e75f00f0fa824908302fa5dab375c8029b169848525548f61add2955845b9810fe817fcc7581efd11aaac110560a2cc78ae6a20cc6216a0b86fa0d061a57f84bacbf84af84ec31b4"
        );
        assert_eq!(
            decrypt_record(
                &record,
                &auth_key,
                Direction::ClientToServer,
                fields.session_id,
                &BTreeSet::from([fields.server_salt]),
                1_700_000_000,
            ),
            Ok(fields.clone())
        );
        let mut tampered = record.clone();
        tampered[40] ^= 1;
        assert!(decrypt_record(
            &tampered,
            &auth_key,
            Direction::ClientToServer,
            fields.session_id,
            &BTreeSet::from([fields.server_salt]),
            1_700_000_000,
        ).is_err());
    }

    #[test]
    fn receive_window_accepts_fresh_out_of_order_ids() {
        let mut window = ReceiveMessageWindow::new(3);
        assert!(window.claim(8));
        assert!(window.claim(4));
        assert!(window.claim(12));
        assert!(!window.claim(8));
        assert!(window.claim(16));
        assert!(!window.claim(4));
    }

    #[test]
    fn matches_inline_application_constructor_vectors() {
        let payload = [8, 150, 1];
        assert_eq!(
            hex(&encode_inline_invoke(&payload, INLINE_REALTIME_LAYER).unwrap()),
            "a64a7deb0300000003089601"
        );
        assert_eq!(
            hex(&encode_inline_result(&payload).unwrap()),
            "54dc3dac03089601"
        );
        assert_eq!(
            hex(&encode_inline_update(&payload).unwrap()),
            "982c41dc03089601"
        );
        assert_eq!(
            decode_inline_application_object(
                &encode_inline_invoke(&payload, INLINE_REALTIME_LAYER).unwrap()
            ),
            Ok(InlineApplicationObject::Invoke {
                layer: 3,
                payload: payload.to_vec()
            })
        );
    }
}
