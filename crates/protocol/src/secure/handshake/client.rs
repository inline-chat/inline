//! Client state machine for Telegram-compatible authorization-key negotiation.

use super::{
    RsaPublicKey, bind_retry_id, derive_auth_key, derive_temporary_aes, factor_pq,
    initial_server_salt, new_nonce_hash, rsa_pad, server_dh_failure_hash, validate_dh_parameters,
    validate_dh_public_value,
};
use crate::secure::{InvalidEncryptedRecord, aes_ige_decrypt, aes_ige_encrypt, auth_key_id};
use sha1::{Digest, Sha1};

const RES_PQ: u32 = 0x0516_2463;
const PQ_INNER_DC: u32 = 0xa9f5_5f95;
const PQ_INNER_TEMP_DC: u32 = 0x56fd_df88;
const SERVER_DH_PARAMS_OK: u32 = 0xd0e8_075c;
const SERVER_DH_PARAMS_FAIL: u32 = 0x79cb_045d;
const SERVER_DH_INNER: u32 = 0xb589_0dba;
const CLIENT_DH_INNER: u32 = 0x6643_b654;
const DH_GEN_OK: u32 = 0x3bcb_f734;
const DH_GEN_RETRY: u32 = 0x46dc_1fb9;
const DH_GEN_FAIL: u32 = 0xa69d_ae02;
const REQ_PQ_MULTI: u32 = 0xbe7e_8ef1;
const REQ_DH_PARAMS: u32 = 0xd712_e4be;
const SET_CLIENT_DH_PARAMS: u32 = 0xf504_5f1f;
const VECTOR: u32 = 0x1cb5_c415;

/// Established authorization key returned by a successful handshake.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EstablishedAuthorizationKey {
    /// Exact 256-byte shared key. Callers must store this as secret material.
    pub key: [u8; 256],
    /// Telegram-compatible authorization-key identifier.
    pub key_id: [u8; 8],
    /// Initial authenticated server salt.
    pub server_salt: i64,
    /// Whether the key has a bounded lifetime.
    pub temporary: bool,
    /// Authenticated expiry time for a temporary key.
    pub expires_at: Option<i32>,
}

/// Output from one handshake response.
pub enum ClientHandshakeResult {
    /// Send this next unencrypted TL body.
    Request(Vec<u8>),
    /// The authorization key is established.
    Established {
        /// Negotiated key material.
        authorization: EstablishedAuthorizationKey,
        /// Authenticated server Unix time.
        server_time: i32,
    },
}

type RandomBytes = Box<dyn FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord> + Send>;

enum Phase {
    Idle,
    Pq {
        nonce: [u8; 16],
        temporary: bool,
    },
    ServerDh {
        nonce: [u8; 16],
        server_nonce: [u8; 16],
        new_nonce: [u8; 32],
        temporary: bool,
        key: RsaPublicKey,
    },
    DhResult {
        nonce: [u8; 16],
        server_nonce: [u8; 16],
        new_nonce: [u8; 32],
        temporary: bool,
        prime: Vec<u8>,
        g_a: Vec<u8>,
        auth_key: [u8; 256],
        retries: u8,
        server_time: i32,
    },
    Complete,
}

/// Single-use client handshake state machine.
pub struct InlineHandshakeClient {
    rsa_keys: Vec<RsaPublicKey>,
    random: RandomBytes,
    dc: i32,
    phase: Phase,
}

impl InlineHandshakeClient {
    /// Creates a handshake client with a pinned key ring and CSPRNG callback.
    pub fn new<F>(rsa_keys: Vec<RsaPublicKey>, dc: i32, random: F) -> Self
    where
        F: FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord> + Send + 'static,
    {
        Self {
            rsa_keys,
            random: Box::new(random),
            dc,
            phase: Phase::Idle,
        }
    }

    /// Begins permanent or temporary authorization-key negotiation.
    pub fn begin(&mut self, temporary: bool) -> Result<Vec<u8>, InvalidEncryptedRecord> {
        if !matches!(self.phase, Phase::Idle) {
            return Err(InvalidEncryptedRecord);
        }
        let mut nonce = [0; 16];
        (self.random)(&mut nonce)?;
        self.phase = Phase::Pq { nonce, temporary };
        Ok(concat(&[&REQ_PQ_MULTI.to_le_bytes(), &nonce]))
    }

    /// Authenticates one server response and returns the next transition.
    pub fn receive(
        &mut self,
        body: &[u8],
    ) -> Result<ClientHandshakeResult, InvalidEncryptedRecord> {
        let phase = std::mem::replace(&mut self.phase, Phase::Complete);
        match phase {
            Phase::Pq { nonce, temporary } => self.receive_pq(body, nonce, temporary),
            Phase::ServerDh {
                nonce,
                server_nonce,
                new_nonce,
                temporary,
                key,
            } => self.receive_server_dh(body, nonce, server_nonce, new_nonce, temporary, key),
            Phase::DhResult {
                nonce,
                server_nonce,
                new_nonce,
                temporary,
                prime,
                g_a,
                auth_key,
                retries,
                server_time,
            } => self.receive_dh_result(
                body,
                nonce,
                server_nonce,
                new_nonce,
                temporary,
                prime,
                g_a,
                auth_key,
                retries,
                server_time,
            ),
            Phase::Idle | Phase::Complete => Err(InvalidEncryptedRecord),
        }
    }

    fn receive_pq(
        &mut self,
        body: &[u8],
        nonce: [u8; 16],
        temporary: bool,
    ) -> Result<ClientHandshakeResult, InvalidEncryptedRecord> {
        let mut reader = Reader::constructor(body, RES_PQ)?;
        require_equal(&reader.fixed(16)?, &nonce)?;
        let server_nonce: [u8; 16] = reader
            .fixed(16)?
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?;
        let pq = reader.bytes()?;
        if reader.u32()? != VECTOR {
            return Err(InvalidEncryptedRecord);
        }
        let count = reader.i32()?;
        if count < 0 || count > 64 {
            return Err(InvalidEncryptedRecord);
        }
        let mut fingerprints = Vec::with_capacity(count as usize);
        for _ in 0..count {
            fingerprints.push(reader.i64()?);
        }
        reader.end()?;
        let key = self
            .rsa_keys
            .iter()
            .find(|key| fingerprints.contains(&key.fingerprint))
            .cloned()
            .ok_or(InvalidEncryptedRecord)?;
        let (p, q) = factor_pq(&pq, &mut self.random)?;
        let mut new_nonce = [0; 32];
        (self.random)(&mut new_nonce)?;
        let inner = encode_pq_inner(
            temporary,
            &pq,
            &p,
            &q,
            &nonce,
            &server_nonce,
            &new_nonce,
            self.dc,
        )?;
        let encrypted =
            rsa_pad(&inner, &key.modulus, &key.exponent, &mut self.random)?.encrypted_data;
        let request = concat(&[
            &REQ_DH_PARAMS.to_le_bytes(),
            &nonce,
            &server_nonce,
            &tl_bytes(&p)?,
            &tl_bytes(&q)?,
            &key.fingerprint.to_le_bytes(),
            &tl_bytes(&encrypted)?,
        ]);
        self.phase = Phase::ServerDh {
            nonce,
            server_nonce,
            new_nonce,
            temporary,
            key,
        };
        Ok(ClientHandshakeResult::Request(request))
    }

    fn receive_server_dh(
        &mut self,
        body: &[u8],
        nonce: [u8; 16],
        server_nonce: [u8; 16],
        new_nonce: [u8; 32],
        temporary: bool,
        key: RsaPublicKey,
    ) -> Result<ClientHandshakeResult, InvalidEncryptedRecord> {
        let id = read_u32(body, 0)?;
        if id == SERVER_DH_PARAMS_FAIL {
            if body.len() != 52 {
                return Err(InvalidEncryptedRecord);
            }
            require_equal(&body[4..20], &nonce)?;
            require_equal(&body[20..36], &server_nonce)?;
            require_equal(&body[36..52], &server_dh_failure_hash(&new_nonce)?)?;
            return Err(InvalidEncryptedRecord);
        }
        let mut reader = Reader::constructor(body, SERVER_DH_PARAMS_OK)?;
        require_equal(&reader.fixed(16)?, &nonce)?;
        require_equal(&reader.fixed(16)?, &server_nonce)?;
        let encrypted = reader.bytes()?;
        reader.end()?;
        let (aes_key, aes_iv) = derive_temporary_aes(&new_nonce, &server_nonce)?;
        let plaintext = aes_ige_decrypt(&encrypted, &aes_key, &aes_iv)?;
        if plaintext.len() < 24 {
            return Err(InvalidEncryptedRecord);
        }
        let mut inner = Reader::constructor(&plaintext[20..], SERVER_DH_INNER)?;
        require_equal(&inner.fixed(16)?, &nonce)?;
        require_equal(&inner.fixed(16)?, &server_nonce)?;
        let generator = inner.i32()?;
        let prime = inner.bytes()?;
        let g_a = inner.bytes()?;
        let server_time = inner.i32()?;
        let consumed = 20 + 4 + inner.offset;
        if plaintext
            .len()
            .checked_sub(consumed)
            .ok_or(InvalidEncryptedRecord)?
            > 15
        {
            return Err(InvalidEncryptedRecord);
        }
        require_equal(&plaintext[..20], &sha1(&plaintext[20..consumed]))?;
        validate_dh_parameters(&prime, generator as u32, &mut self.random)?;
        validate_dh_public_value(&g_a, &prime)?;
        let result = self.make_client_dh(
            nonce,
            server_nonce,
            new_nonce,
            temporary,
            prime,
            g_a,
            0,
            0,
            server_time,
        )?;
        let _ = key;
        Ok(ClientHandshakeResult::Request(result))
    }

    #[allow(clippy::too_many_arguments)]
    fn make_client_dh(
        &mut self,
        nonce: [u8; 16],
        server_nonce: [u8; 16],
        new_nonce: [u8; 32],
        temporary: bool,
        prime: Vec<u8>,
        g_a: Vec<u8>,
        retries: u8,
        retry_id: i64,
        server_time: i32,
    ) -> Result<Vec<u8>, InvalidEncryptedRecord> {
        let mut exponent = [0; 256];
        (self.random)(&mut exponent)?;
        let g_b = derive_auth_key(&[3], &exponent, &prime)?;
        validate_dh_public_value(&g_b, &prime)?;
        let auth_key = derive_auth_key(&g_a, &exponent, &prime)?;
        let serialized = concat(&[
            &CLIENT_DH_INNER.to_le_bytes(),
            &nonce,
            &server_nonce,
            &retry_id.to_le_bytes(),
            &tl_bytes(&g_b)?,
        ]);
        let padding_length = (16 - ((20 + serialized.len()) % 16)) % 16;
        let mut padding = vec![0; padding_length];
        (self.random)(&mut padding)?;
        let (key, iv) = derive_temporary_aes(&new_nonce, &server_nonce)?;
        let encrypted = aes_ige_encrypt(
            &concat(&[&sha1(&serialized), &serialized, &padding]),
            &key,
            &iv,
        )?;
        self.phase = Phase::DhResult {
            nonce,
            server_nonce,
            new_nonce,
            temporary,
            prime,
            g_a,
            auth_key,
            retries,
            server_time,
        };
        Ok(concat(&[
            &SET_CLIENT_DH_PARAMS.to_le_bytes(),
            &nonce,
            &server_nonce,
            &tl_bytes(&encrypted)?,
        ]))
    }

    #[allow(clippy::too_many_arguments)]
    fn receive_dh_result(
        &mut self,
        body: &[u8],
        nonce: [u8; 16],
        server_nonce: [u8; 16],
        new_nonce: [u8; 32],
        temporary: bool,
        prime: Vec<u8>,
        g_a: Vec<u8>,
        auth_key: [u8; 256],
        retries: u8,
        server_time: i32,
    ) -> Result<ClientHandshakeResult, InvalidEncryptedRecord> {
        if body.len() != 52 {
            return Err(InvalidEncryptedRecord);
        }
        require_equal(&body[4..20], &nonce)?;
        require_equal(&body[20..36], &server_nonce)?;
        let id = read_u32(body, 0)?;
        let index = if id == DH_GEN_OK {
            1
        } else if id == DH_GEN_RETRY {
            2
        } else if id == DH_GEN_FAIL {
            3
        } else {
            return Err(InvalidEncryptedRecord);
        };
        require_equal(
            &body[36..52],
            &new_nonce_hash(&new_nonce, index, &auth_key)?,
        )?;
        if id == DH_GEN_FAIL {
            return Err(InvalidEncryptedRecord);
        }
        if id == DH_GEN_RETRY {
            if retries >= 4 {
                return Err(InvalidEncryptedRecord);
            }
            let retry = self.make_client_dh(
                nonce,
                server_nonce,
                new_nonce,
                temporary,
                prime,
                g_a,
                retries + 1,
                bind_retry_id(&auth_key)?,
                server_time,
            )?;
            return Ok(ClientHandshakeResult::Request(retry));
        }
        self.phase = Phase::Complete;
        Ok(ClientHandshakeResult::Established {
            authorization: EstablishedAuthorizationKey {
                key: auth_key,
                key_id: auth_key_id(&auth_key)?,
                server_salt: initial_server_salt(&new_nonce, &server_nonce)?,
                temporary,
                expires_at: temporary.then_some(server_time + 86_400),
            },
            server_time,
        })
    }
}

fn encode_pq_inner(
    temporary: bool,
    pq: &[u8],
    p: &[u8],
    q: &[u8],
    nonce: &[u8; 16],
    server_nonce: &[u8; 16],
    new_nonce: &[u8; 32],
    dc: i32,
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    let mut output = concat(&[
        &(if temporary {
            PQ_INNER_TEMP_DC
        } else {
            PQ_INNER_DC
        })
        .to_le_bytes(),
        &tl_bytes(pq)?,
        &tl_bytes(p)?,
        &tl_bytes(q)?,
        nonce,
        server_nonce,
        new_nonce,
        &dc.to_le_bytes(),
    ]);
    if temporary {
        output.extend_from_slice(&86_400_i32.to_le_bytes());
    }
    Ok(output)
}

fn sha1(value: &[u8]) -> [u8; 20] {
    Sha1::digest(value).into()
}

fn require_equal(left: &[u8], right: &[u8]) -> Result<(), InvalidEncryptedRecord> {
    let mut difference = left.len() ^ right.len();
    for index in 0..left.len().max(right.len()) {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    if difference == 0 {
        Ok(())
    } else {
        Err(InvalidEncryptedRecord)
    }
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    let mut output = Vec::with_capacity(parts.iter().map(|part| part.len()).sum());
    for part in parts {
        output.extend_from_slice(part);
    }
    output
}

fn tl_bytes(value: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
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

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, InvalidEncryptedRecord> {
    Ok(u32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or(InvalidEncryptedRecord)?
            .try_into()
            .map_err(|_| InvalidEncryptedRecord)?,
    ))
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}
impl<'a> Reader<'a> {
    fn constructor(bytes: &'a [u8], expected: u32) -> Result<Self, InvalidEncryptedRecord> {
        if read_u32(bytes, 0)? != expected {
            return Err(InvalidEncryptedRecord);
        }
        Ok(Self {
            bytes: &bytes[4..],
            offset: 0,
        })
    }
    fn fixed(&mut self, length: usize) -> Result<Vec<u8>, InvalidEncryptedRecord> {
        let value = self
            .bytes
            .get(self.offset..self.offset + length)
            .ok_or(InvalidEncryptedRecord)?
            .to_vec();
        self.offset += length;
        Ok(value)
    }
    fn i32(&mut self) -> Result<i32, InvalidEncryptedRecord> {
        Ok(i32::from_le_bytes(
            self.fixed(4)?
                .try_into()
                .map_err(|_| InvalidEncryptedRecord)?,
        ))
    }
    fn u32(&mut self) -> Result<u32, InvalidEncryptedRecord> {
        Ok(u32::from_le_bytes(
            self.fixed(4)?
                .try_into()
                .map_err(|_| InvalidEncryptedRecord)?,
        ))
    }
    fn i64(&mut self) -> Result<i64, InvalidEncryptedRecord> {
        Ok(i64::from_le_bytes(
            self.fixed(8)?
                .try_into()
                .map_err(|_| InvalidEncryptedRecord)?,
        ))
    }
    fn bytes(&mut self) -> Result<Vec<u8>, InvalidEncryptedRecord> {
        let first = *self.bytes.get(self.offset).ok_or(InvalidEncryptedRecord)?;
        let (length, header) = if first < 254 {
            (usize::from(first), 1)
        } else if first == 254 {
            let length = usize::from(
                *self
                    .bytes
                    .get(self.offset + 1)
                    .ok_or(InvalidEncryptedRecord)?,
            ) | usize::from(
                *self
                    .bytes
                    .get(self.offset + 2)
                    .ok_or(InvalidEncryptedRecord)?,
            ) << 8
                | usize::from(
                    *self
                        .bytes
                        .get(self.offset + 3)
                        .ok_or(InvalidEncryptedRecord)?,
                ) << 16;
            (length, 4)
        } else {
            return Err(InvalidEncryptedRecord);
        };
        let start = self.offset + header;
        let total = (header + length).next_multiple_of(4);
        let value = self
            .bytes
            .get(start..start + length)
            .ok_or(InvalidEncryptedRecord)?
            .to_vec();
        if self
            .bytes
            .get(start + length..self.offset + total)
            .ok_or(InvalidEncryptedRecord)?
            .iter()
            .any(|byte| *byte != 0)
        {
            return Err(InvalidEncryptedRecord);
        }
        self.offset += total;
        Ok(value)
    }
    fn end(&self) -> Result<(), InvalidEncryptedRecord> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(InvalidEncryptedRecord)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::collections::VecDeque;

    #[test]
    fn matches_frozen_typescript_permanent_handshake() {
        let corpus: Value =
            serde_json::from_str(include_str!("../../../vectors/inline-protocol-v1.json")).unwrap();
        let transcript = &corpus["handshakeTranscripts"]["permanent"];
        let calls = transcript["clientRandomCalls"]
            .as_array()
            .unwrap()
            .iter()
            .map(|call| hex::decode(call["hex"].as_str().unwrap()).unwrap())
            .collect::<VecDeque<_>>();
        let mut calls = calls;
        let random = move |output: &mut [u8]| {
            let value = calls.pop_front().ok_or(InvalidEncryptedRecord)?;
            if value.len() != output.len() {
                return Err(InvalidEncryptedRecord);
            }
            output.copy_from_slice(&value);
            Ok(())
        };
        let key = RsaPublicKey {
            modulus: hex::decode(transcript["rsaModulusHex"].as_str().unwrap()).unwrap(),
            exponent: hex::decode(transcript["rsaExponentHex"].as_str().unwrap()).unwrap(),
            fingerprint: transcript["rsaFingerprint"]
                .as_str()
                .unwrap()
                .parse()
                .unwrap(),
        };
        let requests = transcript["requestHex"].as_array().unwrap();
        let responses = transcript["responseHex"].as_array().unwrap();
        let mut client = InlineHandshakeClient::new(vec![key], 1, random);
        assert_eq!(hex::encode(client.begin(false).unwrap()), requests[0]);
        for index in 0..2 {
            let response = hex::decode(responses[index].as_str().unwrap()).unwrap();
            let ClientHandshakeResult::Request(request) = client.receive(&response).unwrap() else {
                panic!("handshake completed early")
            };
            assert_eq!(hex::encode(request), requests[index + 1]);
        }
        let response = hex::decode(responses[2].as_str().unwrap()).unwrap();
        let ClientHandshakeResult::Established { authorization, .. } =
            client.receive(&response).unwrap()
        else {
            panic!("handshake did not complete")
        };
        assert_eq!(hex::encode(authorization.key), transcript["authKeyHex"]);
        assert_eq!(
            hex::encode(authorization.key_id),
            transcript["authKeyIdHex"]
        );
        assert_eq!(
            authorization.server_salt.to_string(),
            transcript["serverSalt"]
        );
        assert!(!authorization.temporary);
    }
}
