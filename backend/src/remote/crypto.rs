//! RFC 9180 authenticated HPKE, matching CryptoKit's Curve25519_SHA256_ChachaPoly.
//! Each direction has its own ordered context. The host challenge binds client
//! commands; the host response also binds the client's fresh encapsulated key,
//! so even a malicious relay replaying a challenge cannot replay an old ready.
use crate::{Error, Result};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use hpke::{
    Deserializable, Kem as KemTrait, OpModeR, OpModeS, Serializable, aead::ChaCha20Poly1305,
    kdf::HkdfSha256, kem::X25519HkdfSha256,
};
use serde::{Deserialize, Serialize};
type Kem = X25519HkdfSha256;
type Private = <Kem as KemTrait>::PrivateKey;
type Public = <Kem as KemTrait>::PublicKey;
pub type Receiver = hpke::aead::AeadCtxR<ChaCha20Poly1305, HkdfSha256, Kem>;
pub type Sender = hpke::aead::AeadCtxS<ChaCha20Poly1305, HkdfSha256, Kem>;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Packet {
    pub ciphertext: String,
    pub encapsulated_key: Option<String>,
    pub public_key: Option<String>,
}
pub fn encode(bytes: &[u8]) -> String {
    B64.encode(bytes)
}
pub fn decode(text: &str) -> Result<Vec<u8>> {
    B64.decode(text)
        .map_err(|_| Error::Invalid("Invalid remote packet."))
}
pub fn keypair() -> (String, String) {
    let (private, public) = Kem::gen_keypair(&mut rand::rngs::OsRng);
    (encode(&private.to_bytes()), encode(&public.to_bytes()))
}
pub fn public_key(private: &str) -> Result<String> {
    let key = Private::from_bytes(&decode(private)?).map_err(|_| Error::Storage)?;
    Ok(encode(&Kem::sk_to_pk(&key).to_bytes()))
}
pub const VERSION: u64 = 2;

/// The client KEM output is fresh for every handshake, even if the relay replays
/// the host's challenge. It is authenticated by successfully opening the hello.
pub fn response_context(challenge: &str, client_encapsulated: &str) -> String {
    format!("{challenge}:{client_encapsulated}")
}
fn info(context: &str, direction: &str) -> Vec<u8> {
    format!("exec-remote-v{VERSION}:{direction}:{context}").into_bytes()
}
pub fn receiver(
    private: &str,
    peer: &str,
    encapsulated: &str,
    challenge: &str,
    direction: &str,
) -> Result<Receiver> {
    let private = Private::from_bytes(&decode(private)?).map_err(|_| Error::Internal)?;
    let peer = Public::from_bytes(&decode(peer)?).map_err(|_| Error::Internal)?;
    let enc = <Kem as KemTrait>::EncappedKey::from_bytes(&decode(encapsulated)?)
        .map_err(|_| Error::Internal)?;
    hpke::setup_receiver::<ChaCha20Poly1305, HkdfSha256, Kem>(
        &OpModeR::Auth(peer),
        &private,
        &enc,
        &info(challenge, direction),
    )
    .map_err(|_| Error::Internal)
}
pub fn sender(
    private: &str,
    peer: &str,
    challenge: &str,
    direction: &str,
) -> Result<(String, Sender)> {
    let private = Private::from_bytes(&decode(private)?).map_err(|_| Error::Internal)?;
    let public = Kem::sk_to_pk(&private);
    let peer = Public::from_bytes(&decode(peer)?).map_err(|_| Error::Internal)?;
    let (enc, context) = hpke::setup_sender::<ChaCha20Poly1305, HkdfSha256, Kem, _>(
        &OpModeS::Auth((private, public)),
        &peer,
        &info(challenge, direction),
        &mut rand::rngs::OsRng,
    )
    .map_err(|_| Error::Internal)?;
    Ok((encode(&enc.to_bytes()), context))
}
pub fn seal(context: &mut Sender, data: &[u8]) -> Result<String> {
    Ok(encode(
        &context.seal(data, &[]).map_err(|_| Error::Internal)?,
    ))
}
pub fn open(context: &mut Receiver, text: &str) -> Result<Vec<u8>> {
    context
        .open(&decode(text)?, &[])
        .map_err(|_| Error::Invalid("Remote authentication failed."))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authenticates_identity_challenge_and_sequence() {
        let (a, ap) = keypair();
        let (b, bp) = keypair();
        let (_, wrong) = keypair();
        let (enc, mut tx) = sender(&a, &bp, "challenge", "client").unwrap();
        let mut rx = receiver(&b, &ap, &enc, "challenge", "client").unwrap();
        let packet = seal(&mut tx, b"command").unwrap();
        assert_eq!(open(&mut rx, &packet).unwrap(), b"command");
        assert!(open(&mut rx, &packet).is_err());
        let mut replay = receiver(&b, &ap, &enc, "new-challenge", "client").unwrap();
        assert!(open(&mut replay, &packet).is_err());
        let mut impostor = receiver(&b, &wrong, &enc, "challenge", "client").unwrap();
        assert!(open(&mut impostor, &packet).is_err());
    }
    #[test]
    fn legacy_v1_hello_is_not_accepted_by_v2() {
        let (host, host_public) = keypair();
        let (client, client_public) = keypair();
        let private = Private::from_bytes(&decode(&client).unwrap()).unwrap();
        let public = Public::from_bytes(&decode(&client_public).unwrap()).unwrap();
        let peer = Public::from_bytes(&decode(&host_public).unwrap()).unwrap();
        let (enc, mut tx) = hpke::setup_sender::<ChaCha20Poly1305, HkdfSha256, Kem, _>(
            &OpModeS::Auth((private, public)),
            &peer,
            b"exec-remote-v1:client:challenge",
            &mut rand::rngs::OsRng,
        )
        .unwrap();
        let hello = seal(&mut tx, br#"{"name":"legacy"}"#).unwrap();
        let mut rx = receiver(
            &host,
            &client_public,
            &encode(&enc.to_bytes()),
            "challenge",
            "client",
        )
        .unwrap();
        assert!(open(&mut rx, &hello).is_err());
    }
    #[test]
    fn recorded_host_ready_cannot_authenticate_a_fresh_client_context() {
        let (host, host_public) = keypair();
        let (client, client_public) = keypair();
        let (old_enc, _) = sender(&client, &host_public, "replayed-challenge", "client").unwrap();
        let (new_enc, _) = sender(&client, &host_public, "replayed-challenge", "client").unwrap();
        assert_ne!(old_enc, new_enc);
        let old_context = response_context("replayed-challenge", &old_enc);
        let new_context = response_context("replayed-challenge", &new_enc);
        let (host_enc, mut tx) = sender(&host, &client_public, &old_context, "host").unwrap();
        let ready = seal(&mut tx, br#"{"ready":true,"version":2}"#).unwrap();
        let mut original =
            receiver(&client, &host_public, &host_enc, &old_context, "host").unwrap();
        assert!(open(&mut original, &ready).is_ok());
        let mut replay = receiver(&client, &host_public, &host_enc, &new_context, "host").unwrap();
        assert!(open(&mut replay, &ready).is_err());
    }
}
