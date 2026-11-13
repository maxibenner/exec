//! RFC 9180 authenticated HPKE, matching CryptoKit's Curve25519_SHA256_ChachaPoly.
//! Each direction has its own ordered context. A fresh host challenge binds every
//! connection, so captured handshakes/commands cannot be replayed on another socket.
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
fn info(challenge: &str, direction: &str) -> Vec<u8> {
    format!("exec-remote-v1:{direction}:{challenge}").into_bytes()
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
}
