use std::fs;

use anyhow::{Context, Result};
use tempfile::tempdir;

mod common;

#[test]
fn generate_expected_os_release() -> Result<()> {
    let esp_mountpoint = tempdir()?;
    let tmpdir = tempdir()?;
    let profiles = tempdir()?;

    let generation_link = common::setup_generation_link(tmpdir.path(), profiles.path(), 1)
        .expect("Failed to setup generation link");

    // Expect the 'Built on' date in VERSION_ID to be from the birth time of generation_link
    let expected_built_on = time::OffsetDateTime::from(fs::metadata(generation_link.as_path())?.created()?).date();

    let output0 = common::lanzaboote_install(0, esp_mountpoint.path(), vec![generation_link])?;
    assert!(output0.status.success());

    let stub_data = fs::read(
        esp_mountpoint
            .path()
            .join("EFI/Linux/nixos-generation-1.efi"),
    )?;
    let os_release_section = pe_section(&stub_data, ".osrel")
        .context("Failed to read .osrelease PE section.")?
        .to_owned();

    let expected_os_release_section = format!(r#"ID=lanza
PRETTY_NAME=LanzaOS
VERSION_ID=Generation 1, Built on {}
"#, expected_built_on.to_string());

    assert_eq!(&expected_os_release_section, &String::from_utf8(os_release_section)?);

    Ok(())
}

fn pe_section<'a>(file_data: &'a [u8], section_name: &str) -> Option<&'a [u8]> {
    let pe_binary = goblin::pe::PE::parse(file_data).ok()?;

    pe_binary
        .sections
        .iter()
        .find(|s| s.name().unwrap() == section_name)
        .and_then(|s| {
            let section_start: usize = s.pointer_to_raw_data.try_into().ok()?;
            assert!(s.virtual_size <= s.size_of_raw_data);
            let section_end: usize = section_start + usize::try_from(s.virtual_size).ok()?;
            Some(&file_data[section_start..section_end])
        })
}
