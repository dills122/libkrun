#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use krun::{krun_add_read_only_raw_root_fd, krun_create_ctx, krun_free_ctx};

const FIXTURE_LEN: u64 = 4096;
static FIXTURE_ID: AtomicUsize = AtomicUsize::new(0);

struct Fixture {
    file: Option<File>,
    path: Option<PathBuf>,
    device: u64,
    inode: u64,
}

impl Fixture {
    fn new(label: &str, writable: bool, linked: bool, mode: u32) -> Self {
        let (path, mut writer) = loop {
            let id = FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "libkrun-governed-{label}-{}-{id}",
                std::process::id()
            ));
            match OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(file) => break (path, file),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create fixture: {error}"),
            }
        };
        writer.write_all(&[0x5a; FIXTURE_LEN as usize]).unwrap();
        writer.sync_all().unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();

        let file = if writable {
            writer
        } else {
            let reader = OpenOptions::new().read(true).open(&path).unwrap();
            drop(writer);
            reader
        };
        if !linked {
            fs::remove_file(&path).unwrap();
        }
        let metadata = file.metadata().unwrap();
        Self {
            file: Some(file),
            path: linked.then_some(path),
            device: metadata.dev(),
            inode: metadata.ino(),
        }
    }

    fn fd(&self) -> RawFd {
        self.file.as_ref().unwrap().as_raw_fd()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_file(path);
        }
    }
}

struct Context(u32);

impl Context {
    fn new() -> Self {
        let id = krun_create_ctx();
        assert!(id >= 0);
        Self(id as u32)
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        assert_eq!(krun_free_ctx(self.0), 0);
    }
}

fn open_fds() -> BTreeSet<RawFd> {
    (0..1024)
        .filter(|fd| unsafe { libc::fcntl(*fd, libc::F_GETFD) } >= 0)
        .collect()
}

#[test]
fn bounded_raw_fd_validation_corpus() {
    let context = Context::new();
    let valid = Fixture::new("valid", false, false, 0o400);

    for (fd, device, inode, length, expected) in [
        (-1, valid.device, valid.inode, FIXTURE_LEN, -libc::EINVAL),
        (valid.fd(), 0, valid.inode, FIXTURE_LEN, -libc::EINVAL),
        (valid.fd(), valid.device, 0, FIXTURE_LEN, -libc::EINVAL),
        (valid.fd(), valid.device, valid.inode, 0, -libc::EINVAL),
        (valid.fd(), valid.device, valid.inode, 513, -libc::EINVAL),
        (
            valid.fd(),
            valid.device,
            valid.inode.wrapping_add(1),
            FIXTURE_LEN,
            -libc::ESTALE,
        ),
        (
            valid.fd(),
            valid.device.wrapping_add(1),
            valid.inode,
            FIXTURE_LEN,
            -libc::ESTALE,
        ),
        (
            valid.fd(),
            valid.device,
            valid.inode,
            FIXTURE_LEN + 512,
            -libc::EINVAL,
        ),
    ] {
        assert_eq!(
            krun_add_read_only_raw_root_fd(context.0, fd, device, inode, length),
            expected
        );
    }

    let writable = Fixture::new("writable", true, false, 0o400);
    assert_eq!(
        krun_add_read_only_raw_root_fd(
            context.0,
            writable.fd(),
            writable.device,
            writable.inode,
            FIXTURE_LEN,
        ),
        -libc::EACCES
    );

    for fixture in [
        Fixture::new("linked", false, true, 0o400),
        Fixture::new("mode", false, false, 0o600),
    ] {
        assert_eq!(
            krun_add_read_only_raw_root_fd(
                context.0,
                fixture.fd(),
                fixture.device,
                fixture.inode,
                FIXTURE_LEN,
            ),
            -libc::EINVAL
        );
    }

    let mut pipe_fds = [-1; 2];
    assert_eq!(unsafe { libc::pipe(pipe_fds.as_mut_ptr()) }, 0);
    let pipe_reader = unsafe { OwnedFd::from_raw_fd(pipe_fds[0]) };
    let _pipe_writer = unsafe { OwnedFd::from_raw_fd(pipe_fds[1]) };
    assert_eq!(
        krun_add_read_only_raw_root_fd(context.0, pipe_reader.as_raw_fd(), 1, 1, FIXTURE_LEN,),
        -libc::EINVAL
    );

    let closed_fd = unsafe { libc::dup(valid.fd()) };
    assert!(closed_fd >= 0);
    assert_eq!(unsafe { libc::close(closed_fd) }, 0);
    assert_eq!(
        krun_add_read_only_raw_root_fd(
            context.0,
            closed_fd,
            valid.device,
            valid.inode,
            FIXTURE_LEN,
        ),
        -libc::EBADF
    );

    assert_eq!(
        krun_add_read_only_raw_root_fd(
            context.0,
            valid.fd(),
            valid.device,
            valid.inode,
            FIXTURE_LEN,
        ),
        0
    );
    assert_eq!(
        krun_add_read_only_raw_root_fd(
            context.0,
            valid.fd(),
            valid.device,
            valid.inode,
            FIXTURE_LEN,
        ),
        -libc::EEXIST
    );
}

#[test]
fn descriptor_is_owned_cloexec_and_survives_caller_fd_reuse() {
    let context = Context::new();
    let mut fixture = Fixture::new("ownership", false, false, 0o400);
    let caller_fd = fixture.fd();
    let before = open_fds();

    assert_eq!(
        krun_add_read_only_raw_root_fd(
            context.0,
            caller_fd,
            fixture.device,
            fixture.inode,
            FIXTURE_LEN,
        ),
        0
    );

    let added: Vec<_> = open_fds().difference(&before).copied().collect();
    assert_eq!(added.len(), 1);
    let owned_fd = added[0];
    assert_ne!(owned_fd, caller_fd);
    assert_ne!(
        unsafe { libc::fcntl(owned_fd, libc::F_GETFD) } & libc::FD_CLOEXEC,
        0
    );
    assert_eq!(
        unsafe { libc::fcntl(owned_fd, libc::F_GETFL) } & libc::O_ACCMODE,
        libc::O_RDONLY
    );

    drop(fixture.file.take());
    let replacement = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/null")
        .unwrap();
    let reused = if replacement.as_raw_fd() == caller_fd {
        replacement
    } else {
        assert_eq!(
            unsafe { libc::dup2(replacement.as_raw_fd(), caller_fd) },
            caller_fd
        );
        drop(replacement);
        unsafe { File::from_raw_fd(caller_fd) }
    };
    assert_eq!(reused.as_raw_fd(), caller_fd);

    let inspection_fd = unsafe { libc::dup(owned_fd) };
    assert!(inspection_fd >= 0);
    let metadata = unsafe { File::from_raw_fd(inspection_fd) }
        .metadata()
        .unwrap();
    assert_eq!(metadata.dev(), fixture.device);
    assert_eq!(metadata.ino(), fixture.inode);
    assert_eq!(metadata.nlink(), 0);
    assert_eq!(metadata.permissions().mode() & 0o7777, 0o400);

    drop(context);
    assert_eq!(unsafe { libc::fcntl(owned_fd, libc::F_GETFD) }, -1);
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::EBADF)
    );
    drop(reused);
}
