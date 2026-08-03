use std::cmp::min;
use std::collections::VecDeque;
use std::io;
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::unistd::pipe;
use vm_memory::{Bytes, GuestAddress, GuestMemoryMmap, VolatileSlice};

use super::port::{Port, PortDescription};
use super::port_io::{output_to_raw_fd_dup, PortOutput};
use super::port_queue_mapping::{
    num_queues, port_id_to_queue_idx, queue_idx_to_port_id, QueueDirection,
};
use crate::legacy::DummyIrqChip;
use crate::virtio::queue::tests::VirtQueue;
use crate::virtio::InterruptTransport;

const NEXT: u16 = 1;
const WRITE: u16 = 2;

struct PartialOutput {
    actions: VecDeque<io::Result<usize>>,
    bytes: Arc<Mutex<Vec<u8>>>,
    waits: Arc<AtomicUsize>,
    complete: mpsc::Sender<()>,
    expected: usize,
}

struct DiscardOutput;

impl PortOutput for DiscardOutput {
    fn write_volatile(&mut self, buf: &VolatileSlice) -> io::Result<usize> {
        Ok(buf.len())
    }

    fn wait_until_writable(&self, _stopfd: Option<&utils::eventfd::EventFd>) -> bool {
        true
    }
}

struct ZeroProgressOutput {
    calls: Arc<AtomicUsize>,
    attempted: mpsc::Sender<()>,
}

impl PortOutput for ZeroProgressOutput {
    fn write_volatile(&mut self, _buf: &VolatileSlice) -> io::Result<usize> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.attempted.send(()).unwrap();
        Ok(0)
    }

    fn wait_until_writable(&self, _stopfd: Option<&utils::eventfd::EventFd>) -> bool {
        true
    }
}

impl PortOutput for PartialOutput {
    fn write_volatile(&mut self, buf: &VolatileSlice) -> io::Result<usize> {
        let action = self.actions.pop_front().unwrap_or(Ok(buf.len()));
        let requested = action?;
        let count = min(requested, buf.len());
        let mut chunk = vec![0; count];
        assert_eq!(buf.copy_to(&mut chunk), count);
        let mut bytes = self.bytes.lock().unwrap();
        bytes.extend_from_slice(&chunk);
        if bytes.len() == self.expected {
            self.complete.send(()).unwrap();
        }
        Ok(count)
    }

    fn wait_until_writable(&self, _stopfd: Option<&utils::eventfd::EventFd>) -> bool {
        self.waits.fetch_add(1, Ordering::Relaxed);
        true
    }
}

fn interrupt() -> InterruptTransport {
    InterruptTransport::new(DummyIrqChip::new().into(), "console-coverage".to_string()).unwrap()
}

fn empty_queue<'a>(
    mem: &'a GuestMemoryMmap,
    address: u64,
) -> (VirtQueue<'a>, crate::virtio::Queue) {
    let virtq = VirtQueue::new(GuestAddress(address), mem, 8);
    let queue = virtq.create_queue();
    (virtq, queue)
}

#[test]
#[ignore = "run by the governed bounded coverage corpus"]
fn bounded_directional_ids_and_port_lifecycle_properties() {
    for port_id in 0..=1024 {
        let rx = port_id_to_queue_idx(QueueDirection::Rx, port_id);
        let tx = port_id_to_queue_idx(QueueDirection::Tx, port_id);
        assert_eq!(queue_idx_to_port_id(rx), (QueueDirection::Rx, port_id));
        assert_eq!(queue_idx_to_port_id(tx), (QueueDirection::Tx, port_id));
        assert_ne!(rx, 2);
        assert_ne!(rx, 3);
        assert_ne!(tx, 2);
        assert_ne!(tx, 3);
        assert!(rx < num_queues(port_id + 1));
        assert!(tx < num_queues(port_id + 1));
    }
    for control_queue in [2, 3] {
        assert!(std::panic::catch_unwind(|| queue_idx_to_port_id(control_queue)).is_err());
    }

    let terminal = super::port_io::term_fixed_size(120, 40);
    let mut console = Port::new(0, PortDescription::console(None, None, terminal));
    assert_eq!(console.name(), "");
    assert_eq!(console.terminal().unwrap().get_win_size(), (120, 40));
    console.notify_rx();
    console.notify_tx();

    let mut output = Port::new(
        1,
        PortDescription::output_pipe("stdout", Box::new(DiscardOutput)),
    );
    assert_eq!(output.name(), "stdout");
    assert!(output.terminal().is_none());

    let input = Port::new(
        2,
        PortDescription::input_pipe("stdin", super::port_io::input_empty().unwrap()),
    );
    assert_eq!(input.name(), "stdin");

    let mem = GuestMemoryMmap::from_ranges(&[(GuestAddress(0), 0x10_000)]).unwrap();
    let (_rx, rx_queue) = empty_queue(&mem, 0);
    let (_tx, tx_queue) = empty_queue(&mem, 0x400);
    console.start(
        mem.clone(),
        rx_queue,
        tx_queue,
        interrupt(),
        super::console_control::ConsoleControl::new(),
    );
    assert!(console.is_active());
    console.notify_rx();
    console.notify_tx();
    console.shutdown();
    assert!(!console.is_active());
    console.shutdown();

    output.shutdown();
}

#[test]
#[ignore = "run by the governed bounded coverage corpus"]
fn partial_writes_and_descriptor_direction_are_accounted_once() {
    let payload = b"bounded-partial-write";
    let mem = GuestMemoryMmap::from_ranges(&[(GuestAddress(0), 0x10_000)]).unwrap();
    let (_rx, rx_queue) = empty_queue(&mem, 0);
    let tx_virtq = VirtQueue::new(GuestAddress(0x400), &mem, 8);
    mem.write_slice(payload, GuestAddress(0x2000)).unwrap();
    mem.write_slice(b"ignored", GuestAddress(0x3000)).unwrap();
    tx_virtq.dtable[0].set(0x2000, payload.len() as u32, NEXT, 1);
    tx_virtq.dtable[1].set(0x3000, 7, WRITE, 0);
    tx_virtq.avail.ring[0].set(0);
    tx_virtq.avail.idx.set(1);

    let bytes = Arc::new(Mutex::new(Vec::new()));
    let waits = Arc::new(AtomicUsize::new(0));
    let (complete_tx, complete_rx) = mpsc::channel();
    let partial = PartialOutput {
        actions: VecDeque::from([
            Err(io::Error::from(io::ErrorKind::WouldBlock)),
            Ok(1),
            Ok(2),
            Ok(3),
        ]),
        bytes: Arc::clone(&bytes),
        waits: Arc::clone(&waits),
        complete: complete_tx,
        expected: payload.len(),
    };
    let mut port = Port::new(
        7,
        PortDescription::output_pipe("partial", Box::new(partial)),
    );
    port.start(
        mem.clone(),
        rx_queue,
        tx_virtq.create_queue(),
        interrupt(),
        super::console_control::ConsoleControl::new(),
    );
    complete_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    port.shutdown();

    assert_eq!(&*bytes.lock().unwrap(), payload);
    assert_eq!(waits.load(Ordering::Relaxed), 1);
    assert_eq!(tx_virtq.used.idx.get(), 1);
    assert_eq!(tx_virtq.used.ring[0].get().id, 0);
    assert_eq!(tx_virtq.used.ring[0].get().len, payload.len() as u32);
}

#[test]
#[ignore = "run by the governed bounded coverage corpus"]
fn shutdown_cancels_a_queued_backpressured_write() {
    let (reader, writer) = pipe().unwrap();
    let output = output_to_raw_fd_dup(writer.as_raw_fd()).unwrap();
    let fill = [0u8; 4096];
    loop {
        let written = unsafe {
            libc::write(
                writer.as_raw_fd(),
                fill.as_ptr().cast::<libc::c_void>(),
                fill.len(),
            )
        };
        if written < 0 {
            assert_eq!(Errno::last(), Errno::EAGAIN);
            break;
        }
    }

    let mem = GuestMemoryMmap::from_ranges(&[(GuestAddress(0), 0x10_000)]).unwrap();
    let (_rx, rx_queue) = empty_queue(&mem, 0);
    let tx_virtq = VirtQueue::new(GuestAddress(0x400), &mem, 8);
    mem.write_slice(b"blocked", GuestAddress(0x2000)).unwrap();
    tx_virtq.dtable[0].set(0x2000, 7, 0, 0);
    tx_virtq.avail.ring[0].set(0);
    tx_virtq.avail.idx.set(1);

    let interrupt = interrupt();
    let mut port = Port::new(9, PortDescription::output_pipe("blocked", output));
    port.start(
        mem.clone(),
        rx_queue,
        tx_virtq.create_queue(),
        interrupt.clone(),
        super::console_control::ConsoleControl::new(),
    );

    let deadline = Instant::now() + Duration::from_secs(2);
    while interrupt.status().load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert_ne!(interrupt.status().load(Ordering::SeqCst), 0);

    port.shutdown();
    assert!(!port.is_active());
    assert_eq!(tx_virtq.used.idx.get(), 0);
    drop(reader);
    drop(writer);
}

#[test]
#[ignore = "run by the governed bounded coverage corpus"]
fn zero_progress_is_parked_instead_of_busy_looping() {
    let mem = GuestMemoryMmap::from_ranges(&[(GuestAddress(0), 0x10_000)]).unwrap();
    let (_rx, rx_queue) = empty_queue(&mem, 0);
    let tx_virtq = VirtQueue::new(GuestAddress(0x400), &mem, 8);
    mem.write_slice(b"no-progress", GuestAddress(0x2000))
        .unwrap();
    tx_virtq.dtable[0].set(0x2000, 11, 0, 0);
    tx_virtq.avail.ring[0].set(0);
    tx_virtq.avail.idx.set(1);

    let calls = Arc::new(AtomicUsize::new(0));
    let (attempted_tx, attempted_rx) = mpsc::channel();
    let output = ZeroProgressOutput {
        calls: Arc::clone(&calls),
        attempted: attempted_tx,
    };
    let mut port = Port::new(10, PortDescription::output_pipe("zero", Box::new(output)));
    port.start(
        mem.clone(),
        rx_queue,
        tx_virtq.create_queue(),
        interrupt(),
        super::console_control::ConsoleControl::new(),
    );
    attempted_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    std::thread::sleep(Duration::from_millis(10));
    assert_eq!(calls.load(Ordering::Relaxed), 1);

    port.shutdown();
    assert!(!port.is_active());
    assert_eq!(calls.load(Ordering::Relaxed), 1);
    assert_eq!(tx_virtq.used.idx.get(), 0);
}
