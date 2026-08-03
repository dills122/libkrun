use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::{io, thread};

use utils::eventfd::EventFd;
use vm_memory::{GuestMemory, GuestMemoryError, GuestMemoryMmap, GuestMemoryRegion};

use crate::virtio::console::port_io::PortOutput;
use crate::virtio::{DescriptorChain, InterruptTransport, Queue};

pub(crate) fn process_tx(
    mem: GuestMemoryMmap,
    mut queue: Queue,
    interrupt: InterruptTransport,
    output: Arc<Mutex<Box<dyn PortOutput + Send>>>,
    stopfd: EventFd,
    stop: Arc<AtomicBool>,
) {
    loop {
        let Some(head) = pop_head_blocking(&mut queue, &mem, &interrupt, &stop) else {
            return;
        };

        let head_index = head.index;
        let mut bytes_written = 0;

        'descriptors: for desc in head.into_iter().readable() {
            let desc_len = desc.len as usize;
            match write_desc_to_output(
                desc,
                output.lock().unwrap().as_mut(),
                &interrupt,
                &stopfd,
                &stop,
            ) {
                Ok(0) => {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    break;
                }
                Ok(n) => {
                    bytes_written += n;
                    if n < desc_len {
                        break 'descriptors;
                    }
                }
                Err(e) => {
                    log::error!("Failed to write output: {e}");
                    if matches!(e, GuestMemoryError::IOError(e) if e.kind() == io::ErrorKind::BrokenPipe)
                    {
                        // Errors could conceivably be spurious. Broken
                        // pipe is not and there is no point in attempting
                        // to write more.
                        return;
                    }
                }
            }
        }

        if bytes_written == 0 {
            log::trace!("Tx Add used {bytes_written}");
            queue.undo_pop();
            interrupt.signal_used_queue();
            thread::park();
        } else {
            log::trace!("Tx add used {bytes_written}");
            if let Err(e) = queue.add_used(&mem, head_index, bytes_written as u32) {
                error!("failed to add used elements to the queue: {e:?}");
            }
        }
    }
}

fn pop_head_blocking<'mem>(
    queue: &mut Queue,
    mem: &'mem GuestMemoryMmap,
    interrupt: &InterruptTransport,
    stop: &AtomicBool,
) -> Option<DescriptorChain<'mem>> {
    loop {
        match queue.pop(mem) {
            Some(descriptor) => break Some(descriptor),
            None => {
                interrupt.signal_used_queue();
                if stop.load(Ordering::Acquire) {
                    break None;
                }
                thread::park();
                log::trace!("tx unparked, queue len {}", queue.len(mem))
            }
        }
    }
}

fn write_desc_to_output(
    desc: DescriptorChain,
    output: &mut (dyn PortOutput + Send),
    interrupt: &InterruptTransport,
    stopfd: &EventFd,
    stop: &AtomicBool,
) -> Result<usize, GuestMemoryError> {
    // TODO: Switch to using `get_slices()` with the next vm-memory
    //       bump.
    #[allow(deprecated)]
    let mut deferred_error = None;
    let result = desc
        .mem
        .try_access(desc.len as usize, desc.addr, |_, len, addr, region| {
            let src = region.get_slice(addr, len).unwrap();
            loop {
                if stop.load(Ordering::Acquire) {
                    return Ok(0);
                }
                log::trace!("Tx {src:?}, write_volatile {len} bytes");
                match output.write_volatile(&src) {
                    // try_access seem to handle partial write for us (we will be invoked again with an offset)
                    Ok(n) => break Ok(n),
                    // We can't return an error otherwise we would not know how many bytes were processed before WouldBlock
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        log::trace!("Tx wait for output (would block)");
                        interrupt.signal_used_queue();
                        if !output.wait_until_writable(Some(stopfd)) {
                            return Ok(0);
                        }
                    }
                    Err(e) => {
                        deferred_error = Some(GuestMemoryError::IOError(e));
                        break Ok(0);
                    }
                }
            }
        });

    match (result, deferred_error) {
        (Ok(0), Some(error)) => Err(error),
        (Ok(bytes_written), Some(error)) => {
            log::error!("Console output stopped after {bytes_written} bytes: {error}");
            Ok(bytes_written)
        }
        (result, _) => result,
    }
}
