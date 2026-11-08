//! Installs the DeveloperDiskImage cryptex on a target that has none, so the
//! target does not need to be prepared by Xcode or another tool first.
//!
//! The image files are fetched from a pinned commit of
//! `doronz88/DeveloperDiskImage` and accepted only when every file matches its
//! reviewed SHA-256 digest. They are cached in the app container. Apple signs
//! a Cryptex1 ticket for the target over TSS, and `cryptexd` installs it.

use std::path::{Path, PathBuf};

use idevice::{
    http::HttpRequest,
    services::cryptexd::{self, assets::Cryptex1Assets},
};
use sha2::{Digest, Sha256};

use super::*;

/// Commit of `doronz88/DeveloperDiskImage` the digests below were taken from.
const DDI_SOURCE_REVISION: &str = "e2aaeac89ca8fa56c2fa1f144d182994e07a525b";
const DDI_SOURCE_DIRECTORY: &str = "PersonalizedImages/Xcode_iOS_DDI_Cryptex";

/// Every file `Cryptex1Assets::load` reads, with its reviewed digest.
const DDI_FILES: [(&str, &str); 5] = [
    (
        "BuildManifest.plist",
        "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012",
    ),
    (
        "Image.dmg",
        "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176",
    ),
    (
        "Image.dmg.cryptex_info",
        "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c",
    ),
    (
        "Image.dmg.root_hash",
        "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302",
    ),
    (
        "Image.dmg.trustcache",
        "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0",
    ),
];

/// Upper bound for one downloaded file; the image itself is about 16 MB.
const MAX_DDI_FILE_BYTES: usize = 64 * 1024 * 1024;
const DDI_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// Covers the TSS round trip and streaming the image through the tunnel.
const DDI_INSTALL_TIMEOUT: Duration = Duration::from_secs(5 * 60);

/// Downloads (or reuses cached) image files and installs the DDI cryptex.
pub(super) async fn install_developer_image(
    provider: &mut impl RsdProvider,
    handshake: &mut RsdHandshake,
) -> Result<(), PublicFailure> {
    let directory = cache_directory();
    stage(
        DDI_DOWNLOAD_TIMEOUT,
        developer_image_download_failed(),
        ensure_files(&directory),
    )
    .await?;
    let assets = Cryptex1Assets::load(&directory)
        .await
        .map_err(|_| developer_image_download_failed())?;
    stage(
        DDI_INSTALL_TIMEOUT,
        developer_image_install_failed(),
        cryptexd::install_ddi(provider, handshake, &assets),
    )
    .await
    .map(|_| ())
}

/// `$HOME` is the app container on iOS; its `Library/Caches` survives
/// launches but may be purged by the system, in which case files re-download.
fn cache_directory() -> PathBuf {
    let base = std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join("Library").join("Caches"))
        .unwrap_or_else(std::env::temp_dir);
    base.join("DeviceHubDeveloperImage")
        .join(&DDI_SOURCE_REVISION[..12])
}

async fn ensure_files(directory: &Path) -> Result<(), PublicFailure> {
    tokio::fs::create_dir_all(directory)
        .await
        .map_err(|_| developer_image_download_failed())?;
    for (name, expected) in DDI_FILES {
        let path = directory.join(name);
        if let Ok(existing) = tokio::fs::read(&path).await
            && sha256_hex(&existing) == expected
        {
            continue;
        }
        let data = download(name).await?;
        if sha256_hex(&data) != expected {
            return Err(developer_image_download_failed());
        }
        // Write beside the destination and rename, so a partial file is never
        // mistaken for a verified one.
        let partial = directory.join(format!("{name}.partial"));
        tokio::fs::write(&partial, &data)
            .await
            .map_err(|_| developer_image_download_failed())?;
        tokio::fs::rename(&partial, &path)
            .await
            .map_err(|_| developer_image_download_failed())?;
    }
    Ok(())
}

async fn download(name: &str) -> Result<Vec<u8>, PublicFailure> {
    let url = format!(
        "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/{DDI_SOURCE_REVISION}/{DDI_SOURCE_DIRECTORY}/{name}"
    );
    let response = HttpRequest::get(url)
        .https_only()
        .send()
        .await
        .map_err(|_| developer_image_download_failed())?;
    if response.status != 200
        || response.body.is_empty()
        || response.body.len() > MAX_DDI_FILE_BYTES
    {
        return Err(developer_image_download_failed());
    }
    Ok(response.body)
}

fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

const fn developer_image_download_failed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_connection_failed",
        "developer_readiness",
        true,
        "Unable to download a verified developer image.",
    )
}

const fn developer_image_install_failed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_connection_failed",
        "developer_readiness",
        true,
        "Unable to install the developer image on the target.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digests_are_lowercase_sha256_hex() {
        for (name, digest) in DDI_FILES {
            assert_eq!(digest.len(), 64, "{name}");
            assert!(
                digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "{name}"
            );
        }
    }

    #[test]
    fn sha256_hex_matches_a_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn cache_directory_is_scoped_to_the_pinned_revision() {
        assert!(cache_directory().ends_with(Path::new("DeviceHubDeveloperImage/e2aaeac89ca8")));
    }
}
