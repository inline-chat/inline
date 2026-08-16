//! Frozen language-neutral interoperability vectors.

/// Exact Inline Protocol v1 JSON corpus shipped with this crate.
pub const INLINE_PROTOCOL_V1_JSON: &str = include_str!("../vectors/inline-protocol-v1.json");

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn corpus_contains_the_portable_record_and_application_vectors() {
        assert_eq!(
            hex::encode(Sha256::digest(INLINE_PROTOCOL_V1_JSON.as_bytes())),
            "73fbe70763140f91cd1667c9d714848acfe0234a770ee2dfb891939ac2148893"
        );
        let corpus: serde_json::Value = serde_json::from_str(INLINE_PROTOCOL_V1_JSON).unwrap();
        assert_eq!(corpus["formatVersion"], 1);
        assert_eq!(corpus["protocol"], "Inline Protocol v1");
        assert_eq!(
            corpus["encryptedRecords"]["clientToServer"]["recordHex"],
            "32d1586ea457dfc80b016bab73824ee1e75f00f0fa824908302fa5dab375c8029b169848525548f61add2955845b9810fe817fcc7581efd11aaac110560a2cc78ae6a20cc6216a0b86fa0d061a57f84bacbf84af84ec31b4"
        );
        assert_eq!(corpus["applicationObjects"]["invokeHex"], "a64a7deb0300000003089601");
        assert_eq!(corpus["handshakeTranscripts"]["permanent"]["requestHex"].as_array().unwrap().len(), 3);
        assert_eq!(corpus["handshakeTranscripts"]["permanent"]["authKeyHex"].as_str().unwrap().len(), 512);
        assert_eq!(corpus["handshakeTranscripts"]["temporary"]["expiresAt"], 1_700_086_400);
    }
}
