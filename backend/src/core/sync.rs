use super::{ConversationSnapshot, Message};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::io::{self, Write};

pub enum SyncCursor<'a> {
    Latest,
    Before(&'a str),
    After { anchor: &'a str, prefix: &'a str },
}
#[derive(Debug, Serialize)]
pub struct ConversationSync {
    pub snapshot: ConversationSnapshot,
    pub offset: usize,
    pub total: usize,
    pub reset: bool,
    pub prefix: Option<String>,
}
pub(super) const PAGE_SIZE: usize = 32;
// Keep the catch-up window independent of backfill size: valid incremental
// responses include the anchor and may intentionally exceed one page.
pub(super) const AFTER_LOOKUP_SIZE: usize = 64;

struct Prefix {
    // SHA state after '[' and the first n comma-separated messages, before ']'.
    hash: Sha256,
    proof: String,
}
#[derive(Default)]
pub(super) struct PrefixCache {
    prefixes: Vec<Prefix>,
    #[cfg(test)]
    pub serialized: usize,
}
struct HashWriter<'a>(&'a mut Sha256);
impl Write for HashWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
impl PrefixCache {
    /// Call under the state lock *before* editing message index (or replacing history).
    /// A tail edit cannot invalidate the prefix excluding that tail.
    pub fn invalidate(&mut self, index: usize) {
        self.prefixes.truncate(index);
    }
    pub fn proof(&mut self, messages: &[Message], end: usize) -> String {
        if end == 0 {
            return format!("{:x}", Sha256::digest(b"[]"));
        }
        if self.prefixes.len() < end {
            let mut hash = self
                .prefixes
                .last()
                .map(|p| p.hash.clone())
                .unwrap_or_else(|| {
                    let mut hash = Sha256::new();
                    hash.update(b"[");
                    hash
                });
            for (index, message) in messages
                .iter()
                .enumerate()
                .take(end)
                .skip(self.prefixes.len())
            {
                if index != 0 {
                    hash.update(b",");
                }
                serde_json::to_writer(HashWriter(&mut hash), message)
                    .expect("serializable message");
                let mut closed = hash.clone();
                closed.update(b"]");
                self.prefixes.push(Prefix {
                    hash: hash.clone(),
                    proof: format!("{:x}", closed.finalize()),
                });
                #[cfg(test)]
                {
                    self.serialized += 1;
                }
            }
        }
        self.prefixes[end - 1].proof.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proofs_match_old_arrays_and_only_serialize_dirty_suffixes() {
        let mut messages: Vec<_> = (0..200)
            .map(|n| Message::Tool {
                id: n.to_string(),
                call_id: n.to_string(),
                text: format!("quotes \\\" unicode 🦀 {n}"),
                outcome: super::super::ToolOutcome::Completed,
                details: None,
            })
            .collect();
        let mut cache = PrefixCache::default();
        for end in 0..messages.len() {
            assert_eq!(
                cache.proof(&messages, end),
                format!(
                    "{:x}",
                    Sha256::digest(serde_json::to_vec(&messages[..end]).unwrap())
                )
            );
        }
        assert_eq!(cache.serialized, 199);
        for _ in 0..10 {
            cache.proof(&messages, 150);
            cache.proof(&messages, 199);
        }
        cache.invalidate(199);
        cache.proof(&messages, 199);
        assert_eq!(cache.serialized, 199);
        if let Message::Tool { text, .. } = &mut messages[10] {
            *text = "replaced".into();
        }
        cache.invalidate(10);
        assert_eq!(
            cache.proof(&messages, 199),
            format!(
                "{:x}",
                Sha256::digest(serde_json::to_vec(&messages[..199]).unwrap())
            )
        );
        assert_eq!(cache.serialized, 388);
        cache.invalidate(0);
        messages.clear();
        assert_eq!(
            cache.proof(&messages, 0),
            format!("{:x}", Sha256::digest(b"[]"))
        );
    }
}
