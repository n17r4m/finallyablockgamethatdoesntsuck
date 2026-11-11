//! Inputs, acks and pings — the traffic of a match in play — read without touching the heap.
//! A test binary of its own, because it swaps in a counting allocator.

use fbg_proto::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;
static ALLOCS: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::SeqCst);
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
}

#[global_allocator]
static A: Counting = Counting;

#[test]
fn reading_and_writing_play_traffic_never_allocates() {
    let mut m = InputMsg { seat: 1, frontier: 9000, ack: 8990, tick: 9005, advantage: -2, ..Default::default() };
    for k in 0..MAX_CHANGES {
        m.changes.push((8000 + k as i64, (k % 64) as i32));
    }
    for k in 0..MAX_CHECKS {
        m.checks.push((7000 + k as i64 * 12, k as i64 * 0x1234_5678_9abc));
    }
    let frames = [ClientMsg::Input(m).encode(), ServerMsg::Input(m).encode(), ClientMsg::Ping(77).encode(), ServerMsg::Pong(77).encode()];
    let mut out = Vec::with_capacity(8192);

    let before = ALLOCS.load(Ordering::SeqCst);
    for _ in 0..100 {
        for f in &frames {
            let _ = std::hint::black_box(ClientMsg::decode(std::hint::black_box(f)));
            let _ = std::hint::black_box(ServerMsg::decode(std::hint::black_box(f)));
        }
        out.clear();
        ServerMsg::Input(m).encode_into(&mut out);
        ClientMsg::Input(m).encode_into(&mut out);
    }
    assert_eq!(ALLOCS.load(Ordering::SeqCst) - before, 0, "play traffic touched the heap");
    assert!(matches!(ClientMsg::decode(&frames[0]), Ok(Decoded::Msg(ClientMsg::Input(x))) if x == m));
}
