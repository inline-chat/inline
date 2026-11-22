use inline_sdk::{
    InlineProtocolPublicKey, InlineProtocolV3Connection, InlineProtocolV3Options, proto,
};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublicRing {
    rsa_public_key_ring: Vec<InlineProtocolPublicKey>,
}

#[tokio::test]
#[ignore = "requires a local Realtime V3 server and explicit demo credentials"]
async fn native_login_bind_rpc_and_reconnect() {
    let url = std::env::var("INLINE_V3_LIVE_URL").expect("INLINE_V3_LIVE_URL");
    let ring_path = std::env::var("INLINE_V3_PUBLIC_RING").expect("INLINE_V3_PUBLIC_RING");
    let email = std::env::var("INLINE_V3_LIVE_EMAIL").expect("INLINE_V3_LIVE_EMAIL");
    let code = std::env::var("INLINE_V3_LIVE_CODE").expect("INLINE_V3_LIVE_CODE");
    let ring: PublicRing = serde_json::from_slice(&std::fs::read(ring_path).unwrap()).unwrap();
    let keys = ring
        .rsa_public_key_ring
        .into_iter()
        .map(TryInto::try_into)
        .collect::<Result<Vec<_>, _>>()
        .unwrap();

    let mut permanent =
        InlineProtocolV3Connection::connect(InlineProtocolV3Options::permanent(&url, keys.clone()))
            .await
            .unwrap();
    let challenge = permanent
        .auth_begin(proto::AuthBeginRequest {
            identifier: Some(proto::auth_begin_request::Identifier::Email(email)),
            client: Some(proto::ClientInfo {
                client_type: Some("rust-sdk-live-test".into()),
                client_version: Some(env!("CARGO_PKG_VERSION").into()),
                ..Default::default()
            }),
        })
        .await
        .unwrap();
    let completed = permanent
        .auth_complete(proto::AuthCompleteRequest {
            challenge_id: challenge.challenge_id,
            code,
            invite_code: None,
            time_zone: Some("UTC".into()),
        })
        .await
        .unwrap();
    assert!(matches!(
        completed.state,
        Some(proto::auth_complete_result::State::Authorized(_))
    ));

    let permanent_authorization = permanent.authorization();
    let mut temporary_options = InlineProtocolV3Options::permanent(&url, keys);
    temporary_options.temporary = true;
    let mut temporary = InlineProtocolV3Connection::connect(temporary_options)
        .await
        .unwrap();
    temporary
        .bind_temporary(&permanent_authorization)
        .await
        .unwrap();
    temporary
        .call_rpc(proto::RpcCall {
            method: proto::Method::GetMe as i32,
            input: Some(proto::rpc_call::Input::GetMe(proto::GetMeInput {})),
        })
        .await
        .unwrap();

    let temporary_authorization = temporary.authorization();
    drop(temporary);
    let mut reconnected = InlineProtocolV3Connection::connect(InlineProtocolV3Options::reconnect(
        &url,
        temporary_authorization.clone(),
    ))
    .await
    .unwrap();
    reconnected
        .call_rpc(proto::RpcCall {
            method: proto::Method::GetMe as i32,
            input: Some(proto::rpc_call::Input::GetMe(proto::GetMeInput {})),
        })
        .await
        .unwrap();
    drop(reconnected);

    // A process that never learned the server time starts from the device clock; a wrong
    // clock then costs one 16/17 resend instead of failing.
    let learned = inline_sdk::inline_protocol_server_time_offset_millis().unwrap();
    inline_sdk::set_inline_protocol_server_time_offset_millis(None);
    let mut fresh = InlineProtocolV3Connection::connect(InlineProtocolV3Options::reconnect(
        &url,
        temporary_authorization,
    ))
    .await
    .unwrap();
    fresh
        .call_rpc(proto::RpcCall {
            method: proto::Method::GetMe as i32,
            input: Some(proto::rpc_call::Input::GetMe(proto::GetMeInput {})),
        })
        .await
        .unwrap();
    let relearned = inline_sdk::inline_protocol_server_time_offset_millis().unwrap();
    assert!(
        (relearned - learned).abs() < 5_000,
        "offset {learned} then {relearned}"
    );
    if let Ok(expected) = std::env::var("INLINE_V3_LIVE_EXPECTED_OFFSET_MS") {
        let expected: i64 = expected.parse().unwrap();
        assert!(
            (relearned - expected).abs() < 5_000,
            "offset {relearned}, expected {expected}"
        );
    }
}
