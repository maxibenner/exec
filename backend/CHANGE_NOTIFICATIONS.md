# Backend change notifications and lightweight reads

Integration API (also used by the tunnel):

```rust
// core; Serialize + Clone. All revisions are opaque strings.
pub struct ChangeNotification {
    pub epoch: String,
    pub catalog: String,
    pub conversations: std::collections::BTreeMap<String, String>,
}
// AgentManager
pub fn subscribe_changes(&self) -> tokio::sync::watch::Receiver<ChangeNotification>;
// service::Host
pub(crate) fn subscribe_changes(&self) -> tokio::sync::watch::Receiver<ChangeNotification>;
```

`GET /v1/changes` uses the existing HTTP authorization boundary and returns
`application/x-ndjson`: an immediate revision map, then coalesced maps no more
frequently than every 200 ms, with blank-newline heartbeats after about 20 seconds
without output. Request cancellation and service shutdown end the stream. No
transcript bodies appear in notifications. Older servers naturally return 404.

These are invalidations, not events or a replay log. Subscribe **before** reading
state; clone `borrow_and_update()` and release the watch borrow before doing reads,
awaits, or I/O. Refetch changed conversations/catalog, then continue checking the
watch receiver. A new epoch invalidates all remembered revisions. Removed sessions
are absent from the map. A slow observer retains only the latest map, not a queue.
Revisions need only be compared for equality, not interpreted as event counts.

Publication is ordered under the same conversation/catalog locks as mutation.
Every managed instance (including restore, fork, and delegated creation) is attached;
instance registrations fence stale handles after replacement/deletion. Text deltas
and text replacements only advance the conversation revision. Catalog revisions
track the message-free summary, approval changes, library updates, and membership.
Model discovery and account changes also invalidate provider-derived fields such as
context-window usage, which can change independently of the stored record.
Ordinary snapshot/catalog reads do not advance revisions. Notification-only observers
do not cause legacy full-snapshot events to be constructed.

`AgentManager::summaries()` directly projects catalog fields from state without
cloning messages or approvals; `/v1/conversations` keeps its previous JSON shape,
ordering, and unreadable-session entries. The existing `list()` API is unchanged.

`AgentManager::sync()` / `Conversation::sync()` build latest, older and reset pages
of at most 32 messages directly under the state lock, preserving existing offsets,
overlap/reset behavior, and SHA-256-of-JSON-array prefix strings. Incremental `after`
responses include their overlap anchor and every appended message, so may exceed
32 messages; the separate 64-ID anchor lookup window is unchanged. Incremental SHA
states/proofs are cached per message boundary; a request's validation and outgoing proof share the cache.
Tail edits do not invalidate earlier prefixes; edits to historical messages and
record replacement invalidate the affected suffix before it becomes readable.
Warm unchanged/tail polling performs no history serialization/hashing and searches
at most 64 IDs for an `after` cursor. Cold cache fills and invalidated suffixes still
require hashing those messages once; cache memory is linear in message count, not
transcript byte size. Older-page `before` cursor lookup still scans message IDs.
