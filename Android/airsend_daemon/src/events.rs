use crate::protocol::EventEnvelope;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct EventHub {
    sender: broadcast::Sender<EventEnvelope>,
    next_sequence: Arc<Mutex<u64>>,
}

impl EventHub {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity.max(1));
        Self {
            sender,
            next_sequence: Arc::new(Mutex::new(1)),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<EventEnvelope> {
        self.sender.subscribe()
    }

    pub fn publish(&self, event: impl Into<String>, data: Value) -> EventEnvelope {
        let mut next_sequence = self
            .next_sequence
            .lock()
            .expect("event sequence lock poisoned");
        let envelope = EventEnvelope::new(event, *next_sequence, data);
        *next_sequence = next_sequence.saturating_add(1);
        let _ = self.sender.send(envelope.clone());
        envelope
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn subscribed_events_are_ordered() {
        let hub = EventHub::new(16);
        let mut receiver = hub.subscribe();

        hub.publish("state_changed", serde_json::json!({"value": 1}));
        hub.publish("state_changed", serde_json::json!({"value": 2}));

        assert_eq!(receiver.recv().await.unwrap().sequence, 1);
        assert_eq!(receiver.recv().await.unwrap().sequence, 2);
    }

    #[tokio::test]
    async fn lagging_subscriber_does_not_break_publishers() {
        let hub = EventHub::new(1);
        let mut receiver = hub.subscribe();
        hub.publish("state_changed", serde_json::json!({"value": 1}));
        hub.publish("state_changed", serde_json::json!({"value": 2}));

        let error = receiver.recv().await.unwrap_err();

        assert!(matches!(
            error,
            tokio::sync::broadcast::error::RecvError::Lagged(_)
        ));
    }
}
