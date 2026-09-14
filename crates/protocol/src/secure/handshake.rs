//! Exact MTProto authorization-key cryptographic constructions.

use super::{InvalidEncryptedRecord, aes_ige_decrypt, aes_ige_encrypt};
use num_bigint::BigUint;
use sha1::Sha1;
use sha2::{Digest, Sha256};

/// Stateful client authorization-key handshake.
pub mod client;

/// Telegram's built-in 2048-bit safe prime used by Inline Protocol v1.
pub const TELEGRAM_DH_PRIME: [u8; 256] = hex_literal::hex!(
    "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f
     48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c372
     0fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642
     477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4a
     4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754f
     d17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e
     418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d
     8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b"
);

/// Intermediate values frozen by the cross-language RSA_PAD vectors.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RsaPadIntermediate {
    /// Exact unreversed 192-byte inner data and padding.
    pub data_with_padding: Vec<u8>,
    /// Reversed padded data followed by the SHA-256 confirmation.
    pub data_with_hash: Vec<u8>,
    /// AES-256-IGE ciphertext.
    pub aes_encrypted: Vec<u8>,
    /// XOR-adjusted temporary key followed by ciphertext.
    pub key_aes_encrypted: Vec<u8>,
    /// Raw 256-byte RSA result.
    pub encrypted_data: Vec<u8>,
}

/// A pinned RSA public key accepted during authorization-key negotiation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RsaPublicKey {
    /// Unsigned 2048-bit RSA modulus in network byte order.
    pub modulus: Vec<u8>,
    /// Unsigned RSA exponent in network byte order.
    pub exponent: Vec<u8>,
    /// Telegram-compatible signed fingerprint.
    pub fingerprint: i64,
}

fn sha1(parts: &[&[u8]]) -> [u8; 20] {
    let mut hash = Sha1::new();
    for part in parts {
        hash.update(part);
    }
    hash.finalize().into()
}

fn encode_tl_bytes(value: &[u8]) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if value.len() > 0x00ff_ffff {
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

/// Computes Telegram's signed RSA public-key fingerprint.
pub fn rsa_public_key_fingerprint(
    modulus: &[u8],
    exponent: &[u8],
) -> Result<i64, InvalidEncryptedRecord> {
    if modulus.len() != 256 || exponent.is_empty() {
        return Err(InvalidEncryptedRecord);
    }
    let digest = sha1(&[&encode_tl_bytes(modulus)?, &encode_tl_bytes(exponent)?]);
    Ok(i64::from_le_bytes(
        digest[12..20].try_into().expect("fixed SHA-1 slice"),
    ))
}

/// Constructs and validates a pinned RSA public key.
pub fn make_rsa_public_key(
    modulus: Vec<u8>,
    exponent: Vec<u8>,
) -> Result<RsaPublicKey, InvalidEncryptedRecord> {
    let fingerprint = rsa_public_key_fingerprint(&modulus, &exponent)?;
    Ok(RsaPublicKey {
        modulus,
        exponent,
        fingerprint,
    })
}

/// Runs RSA_PAD with fresh caller-supplied randomness, retrying candidates above the modulus.
pub fn rsa_pad<F>(
    serialized_inner: &[u8],
    modulus: &[u8],
    exponent: &[u8],
    mut random_bytes: F,
) -> Result<RsaPadIntermediate, InvalidEncryptedRecord>
where
    F: FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord>,
{
    if serialized_inner.len() > 144 {
        return Err(InvalidEncryptedRecord);
    }
    for _ in 0..64 {
        let mut padding = vec![0; 192 - serialized_inner.len()];
        let mut temporary_key = [0; 32];
        random_bytes(&mut padding)?;
        random_bytes(&mut temporary_key)?;
        if let Ok(result) = rsa_pad_attempt(
            serialized_inner,
            &padding,
            &temporary_key,
            modulus,
            exponent,
        ) {
            return Ok(result);
        }
    }
    Err(InvalidEncryptedRecord)
}

fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part);
    }
    hash.finalize().into()
}

fn fixed_width(value: &BigUint, length: usize) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    let bytes = value.to_bytes_be();
    if bytes.len() > length {
        return Err(InvalidEncryptedRecord);
    }
    let mut output = vec![0; length - bytes.len()];
    output.extend_from_slice(&bytes);
    Ok(output)
}

/// Performs one exact RSA_PAD attempt with fixed randomness.
pub fn rsa_pad_attempt(
    serialized_inner: &[u8],
    random_padding: &[u8],
    temp_key: &[u8],
    modulus_bytes: &[u8],
    exponent_bytes: &[u8],
) -> Result<RsaPadIntermediate, InvalidEncryptedRecord> {
    if serialized_inner.len() > 144
        || serialized_inner.len() + random_padding.len() != 192
        || temp_key.len() != 32
        || modulus_bytes.len() != 256
        || exponent_bytes.is_empty()
    {
        return Err(InvalidEncryptedRecord);
    }
    let mut data_with_padding = serialized_inner.to_vec();
    data_with_padding.extend_from_slice(random_padding);
    let mut data_with_hash = data_with_padding.iter().rev().copied().collect::<Vec<_>>();
    data_with_hash.extend_from_slice(&sha256(&[temp_key, &data_with_padding]));
    let key: [u8; 32] = temp_key.try_into().map_err(|_| InvalidEncryptedRecord)?;
    let aes_encrypted = aes_ige_encrypt(&data_with_hash, &key, &[0; 32])?;
    let aes_hash = sha256(&[&aes_encrypted]);
    let mut key_aes_encrypted = temp_key
        .iter()
        .zip(aes_hash)
        .map(|(left, right)| left ^ right)
        .collect::<Vec<_>>();
    key_aes_encrypted.extend_from_slice(&aes_encrypted);
    let candidate = BigUint::from_bytes_be(&key_aes_encrypted);
    let modulus = BigUint::from_bytes_be(modulus_bytes);
    if candidate >= modulus {
        return Err(InvalidEncryptedRecord);
    }
    let encrypted = candidate.modpow(&BigUint::from_bytes_be(exponent_bytes), &modulus);
    Ok(RsaPadIntermediate {
        data_with_padding,
        data_with_hash,
        aes_encrypted,
        key_aes_encrypted,
        encrypted_data: fixed_width(&encrypted, 256)?,
    })
}

/// Derives the temporary AES key and IV used by both DH inner records.
pub fn derive_temporary_aes(
    new_nonce: &[u8],
    server_nonce: &[u8],
) -> Result<([u8; 32], [u8; 32]), InvalidEncryptedRecord> {
    if new_nonce.len() != 32 || server_nonce.len() != 16 {
        return Err(InvalidEncryptedRecord);
    }
    let nonce_server = sha1(&[new_nonce, server_nonce]);
    let server_nonce_hash = sha1(&[server_nonce, new_nonce]);
    let key: Vec<u8> = nonce_server
        .iter()
        .chain(&server_nonce_hash[..12])
        .copied()
        .collect();
    let nonce_twice = sha1(&[new_nonce, new_nonce]);
    let iv: Vec<u8> = server_nonce_hash[12..]
        .iter()
        .chain(nonce_twice.iter())
        .chain(&new_nonce[..4])
        .copied()
        .collect();
    Ok((
        key.try_into().map_err(|_| InvalidEncryptedRecord)?,
        iv.try_into().map_err(|_| InvalidEncryptedRecord)?,
    ))
}

/// Encrypts one SHA-1-prefixed serialized DH constructor with exact padding.
pub fn encrypt_dh_inner(
    serialized: &[u8],
    padding: &[u8],
    new_nonce: &[u8],
    server_nonce: &[u8],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if padding.len() > 15 || !(20 + serialized.len() + padding.len()).is_multiple_of(16) {
        return Err(InvalidEncryptedRecord);
    }
    let (key, iv) = derive_temporary_aes(new_nonce, server_nonce)?;
    let mut plaintext = sha1(&[serialized]).to_vec();
    plaintext.extend_from_slice(serialized);
    plaintext.extend_from_slice(padding);
    aes_ige_encrypt(&plaintext, &key, &iv)
}

/// Decrypts and verifies exactly one serialized DH constructor.
pub fn decrypt_dh_inner(
    encrypted: &[u8],
    serialized_length: usize,
    new_nonce: &[u8],
    server_nonce: &[u8],
) -> Result<Vec<u8>, InvalidEncryptedRecord> {
    if encrypted.is_empty() || !encrypted.len().is_multiple_of(16) || serialized_length < 4 {
        return Err(InvalidEncryptedRecord);
    }
    let (key, iv) = derive_temporary_aes(new_nonce, server_nonce)?;
    let plaintext = aes_ige_decrypt(encrypted, &key, &iv)?;
    let padding_length = plaintext
        .len()
        .checked_sub(20 + serialized_length)
        .ok_or(InvalidEncryptedRecord)?;
    if padding_length > 15 {
        return Err(InvalidEncryptedRecord);
    }
    let serialized = &plaintext[20..20 + serialized_length];
    if plaintext[..20] != sha1(&[serialized]) {
        return Err(InvalidEncryptedRecord);
    }
    Ok(serialized.to_vec())
}

/// Computes a 256-byte shared authorization key using finite-field DH.
pub fn derive_auth_key(
    public_value: &[u8],
    secret_exponent: &[u8],
    prime_bytes: &[u8],
) -> Result<[u8; 256], InvalidEncryptedRecord> {
    if secret_exponent.len() != 256 || prime_bytes.len() != 256 {
        return Err(InvalidEncryptedRecord);
    }
    fixed_width(
        &BigUint::from_bytes_be(public_value).modpow(
            &BigUint::from_bytes_be(secret_exponent),
            &BigUint::from_bytes_be(prime_bytes),
        ),
        256,
    )?
    .try_into()
    .map_err(|_| InvalidEncryptedRecord)
}

/// Computes the eight-byte authorization-key auxiliary hash.
pub fn auth_key_aux_hash(auth_key: &[u8]) -> Result<[u8; 8], InvalidEncryptedRecord> {
    if auth_key.len() != 256 {
        return Err(InvalidEncryptedRecord);
    }
    Ok(sha1(&[auth_key])[..8]
        .try_into()
        .expect("fixed SHA-1 slice"))
}

/// Computes one of the three server confirmations for a newly negotiated key.
pub fn new_nonce_hash(
    new_nonce: &[u8],
    index: u8,
    auth_key: &[u8],
) -> Result<[u8; 16], InvalidEncryptedRecord> {
    if new_nonce.len() != 32 || !(1..=3).contains(&index) {
        return Err(InvalidEncryptedRecord);
    }
    Ok(
        sha1(&[new_nonce, &[index], &auth_key_aux_hash(auth_key)?])[4..20]
            .try_into()
            .expect("fixed SHA-1 slice"),
    )
}

/// Computes the server's `server_DH_params_fail` confirmation.
pub fn server_dh_failure_hash(new_nonce: &[u8]) -> Result<[u8; 16], InvalidEncryptedRecord> {
    if new_nonce.len() != 32 {
        return Err(InvalidEncryptedRecord);
    }
    Ok(sha1(&[new_nonce])[4..20]
        .try_into()
        .expect("fixed SHA-1 slice"))
}

/// Derives the initial server salt from the handshake nonce chain.
pub fn initial_server_salt(
    new_nonce: &[u8],
    server_nonce: &[u8],
) -> Result<i64, InvalidEncryptedRecord> {
    if new_nonce.len() != 32 || server_nonce.len() != 16 {
        return Err(InvalidEncryptedRecord);
    }
    let mixed: [u8; 8] = std::array::from_fn(|index| new_nonce[index] ^ server_nonce[index]);
    Ok(i64::from_le_bytes(mixed))
}

/// Returns the retry identifier for an authorization-key collision.
pub fn bind_retry_id(auth_key: &[u8]) -> Result<i64, InvalidEncryptedRecord> {
    Ok(i64::from_le_bytes(auth_key_aux_hash(auth_key)?))
}

fn gcd(mut left: u64, mut right: u64) -> u64 {
    while right != 0 {
        (left, right) = (right, left % right);
    }
    left
}

fn modular_multiply(left: u64, right: u64, modulus: u64) -> u64 {
    ((u128::from(left) * u128::from(right)) % u128::from(modulus)) as u64
}

fn minimal_big_endian(value: u64) -> Vec<u8> {
    let bytes = value.to_be_bytes();
    bytes[bytes.iter().position(|byte| *byte != 0).unwrap_or(7)..].to_vec()
}

/// Factors Telegram's bounded `pq` challenge with Pollard rho.
pub fn factor_pq<F>(
    pq_bytes: &[u8],
    mut random_bytes: F,
) -> Result<(Vec<u8>, Vec<u8>), InvalidEncryptedRecord>
where
    F: FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord>,
{
    // TODO(mtproto-v2-compat): Remove this beta-only 8-byte/<2^63 bound and
    // use lossless arbitrary-precision MTProto 2.0 factorization.
    if pq_bytes.is_empty() || pq_bytes.len() > 8 {
        return Err(InvalidEncryptedRecord);
    }
    let mut encoded = [0; 8];
    encoded[8 - pq_bytes.len()..].copy_from_slice(pq_bytes);
    let value = u64::from_be_bytes(encoded);
    if value <= 3 || value >= (1_u64 << 63) {
        return Err(InvalidEncryptedRecord);
    }
    if value.is_multiple_of(2) {
        return Ok((vec![2], minimal_big_endian(value / 2)));
    }
    for _ in 0..32 {
        let mut random = [0; 8];
        random_bytes(&mut random)?;
        let mut x = u64::from_be_bytes(random) % (value - 2) + 2;
        let mut y = x;
        random_bytes(&mut random)?;
        let c = u64::from_be_bytes(random) % (value - 1) + 1;
        let mut divisor = 1;
        for _ in 0..1_000_000 {
            if divisor != 1 {
                break;
            }
            x = (modular_multiply(x, x, value) + c) % value;
            y = (modular_multiply(y, y, value) + c) % value;
            y = (modular_multiply(y, y, value) + c) % value;
            divisor = gcd(x.abs_diff(y), value);
        }
        if divisor > 1 && divisor < value {
            let other = value / divisor;
            let (p, q) = if divisor < other {
                (divisor, other)
            } else {
                (other, divisor)
            };
            return Ok((minimal_big_endian(p), minimal_big_endian(q)));
        }
    }
    Err(InvalidEncryptedRecord)
}

fn generator_matches_prime(prime: &BigUint, generator: u32) -> bool {
    let remainder = |modulus: u32| -> u32 {
        (prime % BigUint::from(modulus))
            .to_u32_digits()
            .first()
            .copied()
            .unwrap_or(0)
    };
    match generator {
        2 => remainder(8) == 7,
        3 => remainder(3) == 2,
        4 => true,
        5 => matches!(remainder(5), 1 | 4),
        6 => matches!(remainder(24), 19 | 23),
        7 => matches!(remainder(7), 3 | 5 | 6),
        _ => false,
    }
}

fn is_probable_prime<F>(
    value: &BigUint,
    random_bytes: &mut F,
    rounds: usize,
) -> Result<bool, InvalidEncryptedRecord>
where
    F: FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord>,
{
    let one = BigUint::from(1_u8);
    let two = BigUint::from(2_u8);
    if value < &two || (value & &one) == BigUint::from(0_u8) {
        return Ok(value == &two);
    }

    let value_minus_one = value - &one;
    let mut odd = value_minus_one.clone();
    let mut power = 0_u32;
    while (&odd & &one) == BigUint::from(0_u8) {
        odd >>= 1;
        power += 1;
    }

    let base_range = value - BigUint::from(3_u8);
    let mut random = [0_u8; 256];
    for _ in 0..rounds {
        let candidate = loop {
            random_bytes(&mut random)?;
            let candidate = BigUint::from_bytes_be(&random);
            if candidate < base_range {
                break candidate;
            }
        };
        let base = candidate + &two;
        let mut witness = base.modpow(&odd, value);
        if witness == one || witness == value_minus_one {
            continue;
        }
        let mut composite = true;
        for _ in 1..power {
            witness = (&witness * &witness) % value;
            if witness == value_minus_one {
                composite = false;
                break;
            }
        }
        if composite {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Validates Telegram's 2048-bit safe-prime and generator rules.
///
/// The built-in Telegram prime is accepted without repeating primality work.
/// For any unfamiliar prime, `random_bytes` must fill its argument from a CSPRNG;
/// it is used for 64 Miller-Rabin rounds for both `p` and `(p - 1) / 2`.
pub fn validate_dh_parameters<F>(
    prime_bytes: &[u8],
    generator: u32,
    mut random_bytes: F,
) -> Result<(), InvalidEncryptedRecord>
where
    F: FnMut(&mut [u8]) -> Result<(), InvalidEncryptedRecord>,
{
    if prime_bytes.len() != 256 || prime_bytes[0] & 0x80 == 0 || !(2..=7).contains(&generator) {
        return Err(InvalidEncryptedRecord);
    }
    let prime = BigUint::from_bytes_be(prime_bytes);
    if !generator_matches_prime(&prime, generator) {
        return Err(InvalidEncryptedRecord);
    }
    if prime_bytes != TELEGRAM_DH_PRIME {
        let half = (&prime - BigUint::from(1_u8)) >> 1;
        if !is_probable_prime(&prime, &mut random_bytes, 64)?
            || !is_probable_prime(&half, &mut random_bytes, 64)?
        {
            return Err(InvalidEncryptedRecord);
        }
    }
    Ok(())
}

/// Backward-compatible built-in-prime validator.
pub fn validate_builtin_dh_parameters(
    prime_bytes: &[u8],
    generator: u32,
) -> Result<(), InvalidEncryptedRecord> {
    if prime_bytes != TELEGRAM_DH_PRIME {
        return Err(InvalidEncryptedRecord);
    }
    validate_dh_parameters(prime_bytes, generator, |_| Err(InvalidEncryptedRecord))
}

/// Enforces Telegram's recommended 64-bit-margin DH public-value bounds.
pub fn validate_dh_public_value(
    value_bytes: &[u8],
    prime_bytes: &[u8],
) -> Result<(), InvalidEncryptedRecord> {
    if value_bytes.is_empty() || value_bytes.len() > 256 || prime_bytes.len() != 256 {
        return Err(InvalidEncryptedRecord);
    }
    let value = BigUint::from_bytes_be(value_bytes);
    let prime = BigUint::from_bytes_be(prime_bytes);
    let margin = BigUint::from(1_u8) << (2048 - 64);
    if value < margin || value > prime - &margin {
        return Err(InvalidEncryptedRecord);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn matches_frozen_rsa_pad_and_temporary_aes_vectors() {
        let modulus = hex::decode("f0d6060f41eb501851051808d4900eb0d044accfe02afbfe3821b6afecf92ffb1c7c8bfbff72e60287f06fe71d03dbf8867c7bd17f7de8bceac32c68543ce43568d6d47c2fd348527a860260cb162c05a8563ca85a62adb9ef469c70449ca31a28b22ccf7e9189d9d75f2998d4f085b2730058fe485f1922ca84ee3913fe3fba65f2a9ca922f105f9c3af8ddca7b4fc039c581796511fc71af021923a889ba42c4bacdd2599d3e97ff00cb390bd09bce84ec14228058cfb9675876b9a1ddc7576a90e7b563d2e018deb0f2dde0282817521a24e8da2f28700856e8667b31c4f304169fc2d575b23b78b050063788e9b4b8b17a43d290e9afde6e3e4a52c94ed1").unwrap();
        let result = rsa_pad_attempt(
            &(0_u8..64).collect::<Vec<_>>(),
            &(0x80_u8..=0xff).collect::<Vec<_>>(),
            &(0x20_u8..0x40).collect::<Vec<_>>(),
            &modulus,
            &[1, 0, 1],
        )
        .unwrap();
        assert_eq!(
            hex(&result.encrypted_data),
            "05a08c73f3cd8e128b23dcdc75d247d723d35436f7716ca13b9b050bf0684bfd6b4915d8679e59f8c28a9ec4e161ad75b74bbdee9e5e480e3178b6edac3c10cc80cde9872cf1213be099e6d6bea74a8d231f36c569e5fba8818a4282191537946e6ad46526249bc4600f960868af9872e4463f7154ac56b00f38c2c028043314d016dda7e0b5b65ea3b211d509c39f17b18d3850a2629dfd1aa3ef129b1d5b8d26bc8b001e5f6134c3f3acefe5974a0072a488e8449ce61fbfc481739948bcead7594d23ffbbc2a9a9ebb168ee707a8567ad28d525cefab2aae6e0d4eb279fe1768a9e6277a53e18e996bc74846cb11ffeb981015a595980b420dc02d124eedd"
        );

        let new_nonce = (0_u8..32).collect::<Vec<_>>();
        let server_nonce = (0xf0_u8..=0xff).collect::<Vec<_>>();
        let (key, iv) = derive_temporary_aes(&new_nonce, &server_nonce).unwrap();
        assert_eq!(
            hex(&key),
            "5f243f0afc16828a28a81163dcf0e3c45e744029e5f224b6de5d8a708e3ead3b"
        );
        assert_eq!(
            hex(&iv),
            "7ddc813131e5cbaae864070e166e6218f6783e8511471a5ab7802cf200010203"
        );
        let serialized = (0x40_u8..0x6b).collect::<Vec<_>>();
        let encrypted = encrypt_dh_inner(&serialized, &[0xaa], &new_nonce, &server_nonce).unwrap();
        assert_eq!(
            hex(&encrypted),
            "f4b876fcb58c64e1d91c8561498104ca5f7cba9c8dae72b335bd6544259c2d54a361efc08a3a19cd6078ac480135a38b73dfba32c4d424659c49f23871107bc4"
        );
        assert_eq!(
            decrypt_dh_inner(&encrypted, serialized.len(), &new_nonce, &server_nonce).unwrap(),
            serialized
        );
    }

    #[test]
    fn accepts_an_unfamiliar_telegram_valid_safe_prime() {
        // RFC 3526 group 14 is an independent 2048-bit safe prime with g = 2.
        let prime = hex::decode(
            "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74\
             020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437\
             4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed\
             ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05\
             98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb\
             9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b\
             e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718\
             3995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff",
        )
        .unwrap();
        let mut round = 0_u8;
        validate_dh_parameters(&prime, 2, |bytes| {
            bytes.fill(round);
            round = round.wrapping_add(1);
            Ok(())
        })
        .unwrap();
        assert_eq!(round, 128);
    }

    #[test]
    fn rejects_bad_generator_congruence_before_primality_work() {
        let mut called = false;
        assert!(
            validate_dh_parameters(&TELEGRAM_DH_PRIME, 2, |_| {
                called = true;
                Ok(())
            })
            .is_err()
        );
        assert!(!called);
    }
}
