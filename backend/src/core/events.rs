use super::ServiceEvent;
use crate::{Error, Result};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use tokio::sync::mpsc;

struct QueuedEvent {
    frame: Arc<ServiceEvent>,
    bytes: usize,
}
struct Observer {
    sender: mpsc::Sender<QueuedEvent>,
    pending: Arc<AtomicUsize>,
    overflow: Arc<AtomicBool>,
}
/// An observer is disconnected when it falls behind, never allowed to block work.
/// Re-subscribe for a current snapshot; events are not a replay log.
pub struct EventReceiver {
    receiver: mpsc::Receiver<QueuedEvent>,
    pending: Arc<AtomicUsize>,
    overflow: Arc<AtomicBool>,
}
impl EventReceiver {
    fn take(&self, event: QueuedEvent) -> Arc<ServiceEvent> {
        self.pending.fetch_sub(event.bytes, Ordering::Relaxed);
        event.frame
    }
    pub async fn recv(&mut self) -> Result<Arc<ServiceEvent>> {
        let error = Error::Invalid("Observer disconnected. Reconnect for a current snapshot.");
        if self.overflow.load(Ordering::Acquire) {
            return Err(error);
        }
        let event = self.receiver.recv().await.ok_or(error.clone())?;
        if self.overflow.load(Ordering::Acquire) {
            return Err(error);
        }
        Ok(self.take(event))
    }
    pub fn try_recv(
        &mut self,
    ) -> std::result::Result<Arc<ServiceEvent>, mpsc::error::TryRecvError> {
        if self.overflow.load(Ordering::Acquire) {
            return Err(mpsc::error::TryRecvError::Disconnected);
        }
        let event = self.receiver.try_recv()?;
        Ok(self.take(event))
    }
}
#[derive(Default)]
pub(super) struct EventHub(Mutex<Vec<Observer>>);
impl EventHub {
    pub fn subscribe(&self) -> EventReceiver {
        // The byte budget is the effective bound. Leave room for small delta
        // bursts within it instead of disconnecting otherwise healthy observers.
        let (sender, receiver) = mpsc::channel(16_384);
        let pending = Arc::new(AtomicUsize::new(0));
        let overflow = Arc::new(AtomicBool::new(false));
        self.0.lock().unwrap().push(Observer {
            sender,
            pending: pending.clone(),
            overflow: overflow.clone(),
        });
        EventReceiver {
            receiver,
            pending,
            overflow,
        }
    }
    pub fn send(&self, frame: Arc<ServiceEvent>) {
        let mut observers = self.0.lock().unwrap();
        if observers.is_empty() {
            return;
        }
        let bytes = serde_json::to_vec(frame.as_ref())
            .expect("serializable runtime event")
            .len()
            + 1;
        observers.retain(|observer| {
            if observer.sender.is_closed() {
                return false;
            }
            let pending = observer.pending.fetch_add(bytes, Ordering::Relaxed);
            // Permit a single large snapshot, as the HTTP implementation does,
            // but never queue more behind it. Both bytes and event count are bounded.
            if (pending != 0 && pending.saturating_add(bytes) > 1024 * 1024)
                || observer
                    .sender
                    .try_send(QueuedEvent {
                        frame: frame.clone(),
                        bytes,
                    })
                    .is_err()
            {
                observer.pending.fetch_sub(bytes, Ordering::Relaxed);
                observer.overflow.store(true, Ordering::Release);
                return false;
            }
            true
        });
    }
}
