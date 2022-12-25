use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use crate::generation::Generation;

#[allow(dead_code)]
#[non_exhaustive]
pub enum EfiFallback {
    X86,
    Arm,
    AArch64
}

// TODO: rethink the API design
impl EfiFallback {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::X86 => "BOOTX64.EFI",
            Self::Arm => "BOOTARM.EFI",
            Self::AArch64 => "BOOTAA64.EFI"
        }
    }

    pub fn as_systemd_filename(&self) -> &'static str {
        match self {
            Self::X86 => "systemd-bootx64.efi",
            Self::Arm => "systemd-bootarm.efi",
            Self::AArch64 => "systemd-bootaa64.efi"
        }
    }

    pub fn from_system_double(system_double: &str) -> Self {
        match system_double {
            "x86_64-linux" => Self::X86,
            "aarch64-linux" => Self::AArch64,
            _ => unimplemented!()
        }
    }
}

pub struct EspPaths {
    pub esp: PathBuf,
    pub nixos: PathBuf,
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub linux: PathBuf,
    pub lanzaboote_image: PathBuf,
    pub efi_fallback_dir: PathBuf,
    pub efi_fallback: PathBuf,
    pub systemd: PathBuf,
    pub systemd_boot: PathBuf,
}

impl EspPaths {
    pub fn new(esp: impl AsRef<Path>, generation: &Generation) -> Result<Self> {
        let esp = esp.as_ref();
        let esp_nixos = esp.join("EFI/nixos");
        let esp_linux = esp.join("EFI/Linux");
        let esp_systemd = esp.join("EFI/systemd");
        let esp_efi_fallback_dir = esp.join("EFI/BOOT");

        let bootspec = &generation.spec.bootspec;
        let efi_fallback = EfiFallback::from_system_double(&generation.spec.bootspec.system);

        Ok(Self {
            esp: esp.to_path_buf(),
            nixos: esp_nixos.clone(),
            kernel: esp_nixos.join(nixos_path(&bootspec.kernel, "bzImage")?),
            initrd: esp_nixos.join(nixos_path(
                bootspec
                    .initrd
                    .as_ref()
                    .context("Lanzaboote does not support missing initrd yet")?,
                "initrd",
            )?),
            linux: esp_linux.clone(),
            lanzaboote_image: esp_linux.join(generation_path(generation)),
            efi_fallback_dir: esp_efi_fallback_dir.clone(),
            efi_fallback: esp_efi_fallback_dir.join(efi_fallback.as_str()),
            systemd: esp_systemd.clone(),
            systemd_boot: esp_systemd.join(efi_fallback.as_systemd_filename()),
        })
    }
}

fn nixos_path(path: impl AsRef<Path>, name: &str) -> Result<PathBuf> {
    let resolved = path
        .as_ref()
        .read_link()
        .unwrap_or_else(|_| path.as_ref().into());

    let parent = resolved.parent().ok_or_else(|| {
        anyhow::anyhow!(format!(
            "Path: {} does not have a parent",
            resolved.display()
        ))
    })?;

    let without_store = parent.strip_prefix("/nix/store").with_context(|| {
        format!(
            "Failed to strip /nix/store from path {}",
            path.as_ref().display()
        )
    })?;

    let nixos_filename = format!("{}-{}.efi", without_store.display(), name);

    Ok(PathBuf::from(nixos_filename))
}

fn generation_path(generation: &Generation) -> PathBuf {
    if let Some(specialisation_name) = generation.is_specialized() {
        PathBuf::from(format!(
            "nixos-generation-{}-specialisation-{}.efi",
            generation, specialisation_name
        ))
    } else {
        PathBuf::from(format!("nixos-generation-{}.efi", generation))
    }
}
