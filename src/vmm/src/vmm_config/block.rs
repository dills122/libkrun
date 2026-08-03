use std::collections::VecDeque;
use std::fmt;
use std::fs::File;
use std::sync::{Arc, Mutex};

use devices::virtio::{
    block::{ImageType, SyncMode},
    Block, CacheType,
};

#[derive(Debug)]
pub enum BlockConfigError {
    /// Failed to create the block device.
    CreateBlockDevice(std::io::Error),
}

impl fmt::Display for BlockConfigError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use self::BlockConfigError::*;
        match *self {
            CreateBlockDevice(ref e) => write!(f, "Cannot create block device: {e:?}"),
        }
    }
}

type Result<T> = std::result::Result<T, BlockConfigError>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlockDeviceConfig {
    pub block_id: String,
    pub cache_type: CacheType,
    pub disk_image_path: String,
    pub disk_image_format: ImageType,
    pub is_disk_read_only: bool,
    pub direct_io: bool,
    pub sync_mode: SyncMode,
}

#[derive(Clone, Debug)]
pub struct ReadOnlyRawRootFdConfig {
    pub file: Arc<File>,
    pub expected_device: u64,
    pub expected_inode: u64,
    pub expected_length: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlockRootConfig {
    pub device: String,
    pub fstype: Option<String>,
    pub options: Option<String>,
}

#[derive(Default)]
pub struct BlockBuilder {
    pub list: VecDeque<Arc<Mutex<Block>>>,
}

impl BlockBuilder {
    pub fn new() -> Self {
        Self {
            list: VecDeque::<Arc<Mutex<Block>>>::new(),
        }
    }

    pub fn insert(&mut self, config: BlockDeviceConfig) -> Result<()> {
        let block_dev = Arc::new(Mutex::new(Self::create_block(config)?));
        self.list.push_back(block_dev);
        Ok(())
    }

    pub fn insert_read_only_raw_root(&mut self, config: ReadOnlyRawRootFdConfig) -> Result<()> {
        let block_dev = Arc::new(Mutex::new(
            devices::virtio::Block::new_read_only_raw_file(
                "vda".to_string(),
                config.file,
                config.expected_device,
                config.expected_inode,
                config.expected_length,
            )
            .map_err(BlockConfigError::CreateBlockDevice)?,
        ));
        self.list.push_back(block_dev);
        Ok(())
    }

    pub fn create_block(config: BlockDeviceConfig) -> Result<Block> {
        devices::virtio::Block::new(
            config.block_id,
            None,
            config.cache_type,
            config.disk_image_path,
            config.disk_image_format,
            config.is_disk_read_only,
            config.direct_io,
            config.sync_mode,
        )
        .map_err(BlockConfigError::CreateBlockDevice)
    }
}
