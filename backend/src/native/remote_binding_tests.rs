use super::*;

fn assert_bound(frontend: &mut NativeConnection, conversation: &str) {
    match frontend.requests.try_recv().expect("missing binding event") {
        NativeEvent::ConversationBound {
            frontend_id,
            conversation_id,
        } => {
            assert_eq!(frontend_id, frontend.id);
            assert_eq!(conversation_id, conversation);
        }
        event => panic!("expected a binding event, got {event:?}"),
    }
}

fn assert_empty(frontend: &mut NativeConnection) {
    assert!(matches!(
        frontend.requests.try_recv(),
        Err(mpsc::error::TryRecvError::Empty)
    ));
}

#[test]
fn remote_binding_requires_explicit_opt_in_but_not_existing_os_permission() {
    let hub = Arc::new(NativeHub::default());
    let conversation = new_id();
    hub.bind_remote(&conversation).unwrap();
    assert!(!hub.permission(&conversation).enabled);

    let mut local_only = hub.register(true, false).unwrap();
    hub.bind_remote(&conversation).unwrap();
    assert!(!hub.permission(&conversation).enabled);
    assert_empty(&mut local_only);

    let mut remote = hub.register(false, true).unwrap();
    let changes = Arc::new(ChangeHub::default());
    hub.attach_changes(&changes);
    let notices = changes.subscribe();
    let before = notices.borrow().catalog.clone();
    assert!(!hub.capture_availability(&conversation, None).available);
    hub.bind_remote(&conversation).unwrap();
    assert!(hub.capture_availability(&conversation, None).available);
    assert_ne!(notices.borrow().catalog, before);
    assert_eq!(hub.bound_frontend(&conversation).unwrap(), remote.id);
    assert!(!hub.approved(&conversation));
    assert_bound(&mut remote, &conversation);
    assert_empty(&mut local_only);
}

#[test]
fn ambiguous_opted_in_frontends_do_not_bind_or_emit_events() {
    let hub = Arc::new(NativeHub::default());
    let mut first = hub.register(true, true).unwrap();
    let mut second = hub.register(false, true).unwrap();
    let conversation = new_id();

    assert!(hub.bind_remote(&conversation).is_err());
    assert_eq!(
        hub.permission(&conversation),
        DesktopPermission {
            frontend_id: None,
            enabled: false,
        }
    );
    assert!(!hub.approved(&conversation));
    assert_empty(&mut first);
    assert_empty(&mut second);
}

#[test]
fn a_full_binding_event_queue_never_grants_desktop_access() {
    let hub = Arc::new(NativeHub::default());
    let mut frontend = hub.register(true, true).unwrap();
    let capacity = frontend.requests.max_capacity();
    for _ in 0..capacity {
        hub.bind_remote(&new_id()).unwrap();
    }
    let conversation = new_id();
    assert!(hub.bind_remote(&conversation).is_err());
    assert!(!hub.permission(&conversation).enabled);
    assert!(hub.bound_frontend(&conversation).is_err());
    assert!(!hub.approved(&conversation));
    for _ in 0..capacity {
        assert!(matches!(
            frontend.requests.try_recv().unwrap(),
            NativeEvent::ConversationBound { conversation_id, .. } if conversation_id != conversation
        ));
    }
    assert_empty(&mut frontend);

    // A subsequent explicit attempt can bind once the notification can be queued.
    hub.bind_remote(&conversation).unwrap();
    assert_bound(&mut frontend, &conversation);
    assert_eq!(hub.bound_frontend(&conversation).unwrap(), frontend.id);
    assert!(!hub.approved(&conversation));
}

#[test]
fn an_existing_live_binding_and_approval_are_untouched_even_with_ambiguous_candidates() {
    let hub = Arc::new(NativeHub::default());
    let mut original = hub.register(true, false).unwrap();
    let conversation = new_id();
    hub.set_permission(
        &conversation,
        DesktopPermission {
            frontend_id: Some(original.id.clone()),
            enabled: true,
        },
    )
    .unwrap();
    hub.approve(&conversation, &original.id).unwrap();
    let mut first = hub.register(true, true).unwrap();
    let mut second = hub.register(true, true).unwrap();

    hub.bind_remote(&conversation).unwrap();
    assert_eq!(hub.bound_frontend(&conversation).unwrap(), original.id);
    assert!(hub.approved(&conversation));
    assert_empty(&mut original);
    assert_empty(&mut first);
    assert_empty(&mut second);
}

#[test]
fn disconnected_or_closed_frontends_are_not_candidates_and_consent_does_not_transfer() {
    for close_receiver_only in [false, true] {
        let hub = Arc::new(NativeHub::default());
        let mut original = hub.register(true, true).unwrap();
        let conversation = new_id();
        hub.bind_remote(&conversation).unwrap();
        assert_bound(&mut original, &conversation);
        hub.approve(&conversation, &original.id).unwrap();
        if close_receiver_only {
            original.requests.close();
        } else {
            drop(original);
            assert!(!hub.permission(&conversation).enabled);
            assert!(!hub.approved(&conversation));
        }
        assert!(hub.bound_frontend(&conversation).is_err());

        let mut replacement = hub.register(true, true).unwrap();
        hub.bind_remote(&conversation).unwrap();
        assert_eq!(hub.bound_frontend(&conversation).unwrap(), replacement.id);
        assert!(!hub.approved(&conversation));
        assert_bound(&mut replacement, &conversation);
    }
}
