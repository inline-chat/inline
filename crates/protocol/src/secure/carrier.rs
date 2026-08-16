//! MTProto obfuscated2 carrier setup and streaming encryption.

use super::InvalidEncryptedRecord;
use aes::Aes256;
use cipher::{BlockEncrypt, KeyInit, generic_array::GenericArray};

const FORBIDDEN_PREFIXES: [u32; 7] = [
    0x4441_4548,
    0x5453_4f50,
    0x2054_4547,
    0x4954_504f,
    0xeeee_eeee,
    0xdddd_dddd,
    0x0201_0316,
];

/// Stateful AES-256-CTR stream used by obfuscated2.
pub struct AesCtrStream {
    cipher: Aes256,
    counter: [u8; 16],
    keystream: [u8; 16],
    position: usize,
}

impl AesCtrStream {
    fn new(key: &[u8], iv: &[u8]) -> Result<Self, InvalidEncryptedRecord> {
        Ok(Self {
            cipher: Aes256::new_from_slice(key).map_err(|_| InvalidEncryptedRecord)?,
            counter: iv.try_into().map_err(|_| InvalidEncryptedRecord)?,
            keystream: [0; 16],
            position: 16,
        })
    }

    /// Encrypts or decrypts the next bytes while preserving stream position.
    pub fn process(&mut self, input: &[u8]) -> Vec<u8> {
        let mut output = Vec::with_capacity(input.len());
        for byte in input {
            if self.position == 16 {
                let mut block = GenericArray::clone_from_slice(&self.counter);
                self.cipher.encrypt_block(&mut block);
                self.keystream.copy_from_slice(&block);
                self.position = 0;
                for counter in self.counter.iter_mut().rev() {
                    *counter = counter.wrapping_add(1);
                    if *counter != 0 {
                        break;
                    }
                }
            }
            output.push(*byte ^ self.keystream[self.position]);
            self.position += 1;
        }
        output
    }
}

/// Client-side obfuscated2 header and both stream directions.
pub struct ObfuscatedClientHeader {
    /// Exact 64-byte header sent on the WebSocket.
    pub wire_header: [u8; 64],
    /// Client-to-server stream after the header has consumed its first 64 bytes.
    pub outbound: AesCtrStream,
    /// Server-to-client stream at offset zero.
    pub inbound: AesCtrStream,
}

/// Returns whether random bytes are safe as an obfuscated2 plaintext header.
pub fn is_valid_obfuscated_header(header: &[u8]) -> bool {
    if header.len() != 64 || header[0] == 0xef {
        return false;
    }
    let first = u32::from_le_bytes(header[..4].try_into().expect("checked header"));
    let second = u32::from_le_bytes(header[4..8].try_into().expect("checked header"));
    !FORBIDDEN_PREFIXES.contains(&first) && second != 0
}

/// Creates a Telegram-compatible obfuscated2 client header for the logical DC.
pub fn create_obfuscated_client_header(
    random_header: &[u8],
    dc: i16,
) -> Result<ObfuscatedClientHeader, InvalidEncryptedRecord> {
    if !is_valid_obfuscated_header(random_header) {
        return Err(InvalidEncryptedRecord);
    }
    let mut plaintext: [u8; 64] = random_header
        .try_into()
        .map_err(|_| InvalidEncryptedRecord)?;
    plaintext[56..60].fill(0xef);
    plaintext[60..62].copy_from_slice(&dc.to_le_bytes());
    let reversed: Vec<u8> = plaintext.iter().rev().copied().collect();
    let mut outbound = AesCtrStream::new(&plaintext[8..40], &plaintext[40..56])?;
    let inbound = AesCtrStream::new(&reversed[8..40], &reversed[40..56])?;
    let encrypted = outbound.process(&plaintext);
    let mut wire_header = plaintext;
    wire_header[56..].copy_from_slice(&encrypted[56..]);
    Ok(ObfuscatedClientHeader {
        wire_header,
        outbound,
        inbound,
    })
}
