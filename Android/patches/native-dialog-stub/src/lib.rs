use std::path::{Path, PathBuf};
use std::error::Error;

pub struct SaveSingleFile<'a> {
    _p: std::marker::PhantomData<&'a ()>,
}

impl<'a> SaveSingleFile<'a> {
    pub fn new() -> Self {
        Self { _p: std::marker::PhantomData }
    }
    pub fn set_location(&mut self, _: &Path) -> &mut Self { self }
    pub fn set_filename(&mut self, _: &str) -> &mut Self { self }
    pub fn show(&self) -> Result<Option<PathBuf>, Box<dyn Error>> {
        Ok(None)
    }
}

pub struct FileDialog { }
impl FileDialog {
    pub fn new() -> Self { Self { } }
    pub fn add_filter(&mut self, _: &str, _: &[&str]) -> &mut Self { self }
    pub fn show_open_single_file(&self) -> Result<Option<PathBuf>, Box<dyn Error>> {
        Ok(None)
    }
}

pub struct MessageDialog { }
impl MessageDialog {
    pub fn new() -> Self { Self { } }
    pub fn set_title(&mut self, _: &str) -> &mut Self { self }
    pub fn set_text(&mut self, _: &str) -> &mut Self { self }
    pub fn set_type(&mut self, _: MessageType) -> &mut Self { self }
    pub fn show_confirm(&self) -> Result<bool, Box<dyn Error>> {
        Ok(true)
    }
}

pub enum MessageType { Info, Warning, Error }
