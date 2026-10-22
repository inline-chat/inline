//! Frozen language-neutral interoperability vectors.

/// Exact Inline Protocol v1 JSON corpus shipped with this crate.
pub const INLINE_PROTOCOL_V1_JSON: &str = include_str!("../vectors/inline-protocol-v1.json");

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secure::binding::create_temporary_key_binding_proof;
    use crate::secure::{Direction, decrypt_record};
    use sha2::{Digest, Sha256};
    use std::collections::BTreeSet;

    #[test]
    fn corpus_contains_the_portable_record_and_application_vectors() {
        assert_eq!(
            hex::encode(Sha256::digest(INLINE_PROTOCOL_V1_JSON.as_bytes())),
            "35a3bccb6e11a934d83e2370e739204144c1d0b89653b7780b22fd124e20b816"
        );
        let corpus: serde_json::Value = serde_json::from_str(INLINE_PROTOCOL_V1_JSON).unwrap();
        assert_eq!(corpus["formatVersion"], 1);
        let service = &corpus["serviceObjects"];
        let packed_result =
            hex::decode(service["gzipPackedRpcResultHex"].as_str().unwrap()).unwrap();
        assert_eq!(packed_result[..4], 0xf35c_6d01_u32.to_le_bytes());
        let stream = crate::secure::gzip_packed_data(&packed_result[12..])
            .unwrap()
            .unwrap();
        let mut inflated = Vec::new();
        std::io::Read::read_to_end(&mut flate2::read::GzDecoder::new(stream), &mut inflated)
            .unwrap();
        assert_eq!(
            hex::encode(inflated),
            service["gzipPackedInnerResultHex"].as_str().unwrap()
        );
        let invoke =
            hex::decode(corpus["applicationObjects"]["invokeHex"].as_str().unwrap()).unwrap();
        assert_eq!(
            hex::encode(
                crate::secure::encode_message_container(&[
                    crate::secure::ContainerMessage {
                        message_id: 4,
                        sequence_number: 1,
                        body: invoke
                    },
                    crate::secure::ContainerMessage {
                        message_id: 8,
                        sequence_number: 0,
                        body: crate::secure::encode_msgs_ack(&[4]),
                    },
                ])
                .unwrap()
            ),
            service["containerHex"].as_str().unwrap()
        );
        assert_eq!(corpus["protocol"], "Inline Protocol v1");
        assert_eq!(
            corpus["encryptedRecords"]["clientToServer"]["recordHex"],
            "32d1586ea457dfc80b016bab73824ee1e75f00f0fa824908302fa5dab375c8029b169848525548f61add2955845b9810fe817fcc7581efd11aaac110560a2cc78ae6a20cc6216a0b86fa0d061a57f84bacbf84af84ec31b4"
        );
        assert_eq!(
            corpus["applicationObjects"]["invokeHex"],
            "a64a7deb0300000003089601"
        );
        assert_eq!(
            corpus["handshakeTranscripts"]["permanent"]["requestHex"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
        assert_eq!(
            corpus["handshakeTranscripts"]["permanent"]["authKeyHex"]
                .as_str()
                .unwrap()
                .len(),
            512
        );
        assert_eq!(
            corpus["handshakeTranscripts"]["temporary"]["expiresAt"],
            1_700_086_400
        );
        assert_eq!(
            corpus["handshakeTranscripts"]["generatorFour"]["generator"],
            4
        );

        let records = &corpus["encryptedRecords"];
        let auth_key =
            hex::decode(records["clientToServer"]["authKeyHex"].as_str().unwrap()).unwrap();
        let server_to_client = decrypt_record(
            &hex::decode(records["serverToClientHex"].as_str().unwrap()).unwrap(),
            &auth_key,
            Direction::ServerToClient,
            0x1112131415161718,
            &BTreeSet::from([0x0102030405060708]),
            1_700_000_000,
        )
        .unwrap();
        assert_eq!(
            hex::encode(server_to_client.body),
            corpus["applicationObjects"]["updateHex"].as_str().unwrap()
        );
        let minimum_padding = decrypt_record(
            &hex::decode(records["minimumPaddingHex"].as_str().unwrap()).unwrap(),
            &auth_key,
            Direction::ClientToServer,
            2,
            &BTreeSet::from([1]),
            1_700_000_000,
        )
        .unwrap();
        assert_eq!(
            hex::encode(minimum_padding.body),
            corpus["serviceObjects"]["destroyAuthKeyHex"]
                .as_str()
                .unwrap()
        );
        let maximum_padding = decrypt_record(
            &hex::decode(records["maximumPaddingHex"].as_str().unwrap()).unwrap(),
            &auth_key,
            Direction::ClientToServer,
            2,
            &BTreeSet::from([1]),
            1_700_000_000,
        )
        .unwrap();
        assert_eq!(maximum_padding.message_id, (1_700_000_000_i64 << 32) | 8);

        let temporary_key = auth_key.iter().map(|byte| 0xff - byte).collect::<Vec<_>>();
        assert_eq!(
            hex::encode(
                create_temporary_key_binding_proof(
                    &auth_key,
                    &temporary_key,
                    123,
                    (1_700_000_000_i64 << 32) | 4,
                    456,
                    1_700_086_400,
                    &[0x11; 16],
                    &[0x22; 8],
                )
                .unwrap()
            ),
            corpus["bindingProofHex"].as_str().unwrap()
        );
    }
}
