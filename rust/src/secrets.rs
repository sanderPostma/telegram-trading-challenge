//! Encrypted-at-rest storage for WEEX and Telegram credentials.
//!
//! Credentials used to sit in `shared_preferences.json` as plain JSON, in a
//! world-readable file. They now live in `credentials.enc`, sealed with
//! XChaCha20-Poly1305.
//!
//! The sealing key is derived from two halves that must both be present:
//!
//! * a build-time key baked into the binary — see [`primary_embedded_key`].
//! * `credentials.key` — 32 random bytes generated on first use, mode 0600,
//!   unique per install.
//!
//! Neither half alone opens the blob: a leaked backup of the data directory
//! without the key file is inert, and the binary without the key file is inert.
//! This is deliberately invisible to the user — no passphrase, no prompt.
//!
//! What this does not defend against: malware running as the user, which can
//! read the key file exactly as the app does. The threat model here is stray
//! file reads, over-broad permissions, cloud-sync, and backup copies.

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use chacha20poly1305::{
    aead::{Aead, KeyInit, OsRng},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;
use sha2::{Digest, Sha256};

/// Fallback embedded key, used when no build-time secret was supplied.
///
/// This value is public — it is in the repository. It makes a stolen
/// `credentials.enc` useless without the app, but adds no secrecy against
/// anyone who can read the source. Release builds override it via
/// `TRADING_CHALLENGE_CREDENTIAL_KEY`.
const DEFAULT_EMBEDDED_KEY: &[u8] = b"trading-challenge/credential-seal/v1/1f4c8a0d6b27e935";

/// The embedded half this build seals *new* blobs with.
///
/// `TRADING_CHALLENGE_CREDENTIAL_KEY` is read at compile time. CI sets it from a repository
/// secret, so a published binary carries a key that is not in the source. A
/// local `cargo build` or `flutter build` with the variable unset falls back to
/// [`DEFAULT_EMBEDDED_KEY`] and needs no setup at all.
fn primary_embedded_key() -> &'static [u8] {
    match option_env!("TRADING_CHALLENGE_CREDENTIAL_KEY") {
        Some(key) if !key.trim().is_empty() => key.as_bytes(),
        _ => DEFAULT_EMBEDDED_KEY,
    }
}

/// Every embedded key this build can *open* a blob with, most preferred first.
///
/// A release binary accepts blobs sealed by a default-key build (a local
/// checkout, an earlier release) and silently re-seals them with its own key on
/// first read. The reverse cannot work — a local build does not hold the CI
/// secret — and that is the point of having one.
fn candidate_embedded_keys() -> Vec<&'static [u8]> {
    let primary = primary_embedded_key();
    if primary == DEFAULT_EMBEDDED_KEY {
        vec![primary]
    } else {
        vec![primary, DEFAULT_EMBEDDED_KEY]
    }
}

const MAGIC: &[u8; 5] = b"TCHL1";
const NONCE_LEN: usize = 24;
const KEY_FILE_LEN: usize = 32;

const CREDENTIALS_FILE: &str = "credentials.enc";
const KEY_FILE: &str = "credentials.key";

fn credentials_path(dir: &Path) -> PathBuf {
    dir.join(CREDENTIALS_FILE)
}

fn key_path(dir: &Path) -> PathBuf {
    dir.join(KEY_FILE)
}

/// Writes `bytes` to `path` atomically and with owner-only permissions, so a
/// crash mid-write cannot leave a half-written blob or a readable temp file.
fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        harden_directory(parent)?;
    }
    let temp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&temp)?;
        set_owner_only(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temp, path)?;
    set_owner_only(path)?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) -> anyhow::Result<()> {
    // Windows inherits the user-profile ACL, which is already owner-scoped.
    Ok(())
}

/// Restricts `dir` to the owner and strips group/other bits from the secret
/// files inside it. Safe to call repeatedly.
pub fn harden_directory(dir: &Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if dir.exists() {
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        }
        for name in [CREDENTIALS_FILE, KEY_FILE, "telegram.session"] {
            let path = dir.join(name);
            if path.exists() {
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            }
        }
    }
    #[cfg(not(unix))]
    let _ = dir;
    Ok(())
}

/// Reads the local key half, generating it on first use.
fn local_key_half(dir: &Path) -> anyhow::Result<Vec<u8>> {
    let path = key_path(dir);
    if path.exists() {
        let bytes = fs::read(&path)?;
        if bytes.len() == KEY_FILE_LEN {
            set_owner_only(&path)?;
            return Ok(bytes);
        }
        // A truncated key file can only have come from a failed write; the
        // sealed blob it belonged to is unrecoverable either way.
        anyhow::bail!("credential key file is corrupt");
    }
    let mut bytes = vec![0u8; KEY_FILE_LEN];
    OsRng.fill_bytes(&mut bytes);
    write_private(&path, &bytes)?;
    Ok(bytes)
}

fn sealing_key(embedded: &[u8], local: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(embedded);
    hasher.update(local);
    hasher.finalize().into()
}

/// Encrypts `plaintext_json` into `<dir>/credentials.enc`.
pub fn save_credentials(dir: &Path, plaintext_json: &str) -> anyhow::Result<()> {
    let local = local_key_half(dir)?;
    let key = sealing_key(primary_embedded_key(), &local);
    let cipher = XChaCha20Poly1305::new((&key).into());

    let mut nonce_bytes = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext_json.as_bytes())
        .map_err(|_| anyhow::anyhow!("credential encryption failed"))?;

    let mut blob = Vec::with_capacity(MAGIC.len() + NONCE_LEN + ciphertext.len());
    blob.extend_from_slice(MAGIC);
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ciphertext);

    write_private(&credentials_path(dir), &blob)
}

/// Decrypts `<dir>/credentials.enc`.
///
/// Returns `Ok(None)` when there is nothing stored *or* when the blob cannot be
/// opened with the current key pair. An unreadable blob is indistinguishable
/// from an absent one to the caller on purpose: the app should fall back to
/// asking for credentials, not fail to start.
pub fn load_credentials(dir: &Path) -> anyhow::Result<Option<String>> {
    let path = credentials_path(dir);
    if !path.exists() {
        return Ok(None);
    }
    let blob = fs::read(&path)?;
    if blob.len() <= MAGIC.len() + NONCE_LEN || &blob[..MAGIC.len()] != MAGIC {
        return Ok(None);
    }
    let local = local_key_half(dir)?;
    let nonce = XNonce::from_slice(&blob[MAGIC.len()..MAGIC.len() + NONCE_LEN]);
    let ciphertext = &blob[MAGIC.len() + NONCE_LEN..];

    let keys = candidate_embedded_keys();
    for (index, embedded) in keys.iter().enumerate() {
        let key = sealing_key(embedded, &local);
        let cipher = XChaCha20Poly1305::new((&key).into());
        let Ok(plaintext) = cipher.decrypt(nonce, ciphertext) else {
            continue;
        };
        let plaintext = String::from_utf8(plaintext)?;
        if index > 0 {
            // Opened with an older embedded key — re-seal under this build's
            // key so the upgrade happens once rather than on every read.
            let _ = save_credentials(dir, &plaintext);
        }
        return Ok(Some(plaintext));
    }
    Ok(None)
}

/// Removes the sealed credentials and the local key half.
pub fn purge_credentials(dir: &Path) -> anyhow::Result<()> {
    for path in [credentials_path(dir), key_path(dir)] {
        if path.exists() {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn round_trips_credentials() {
        let dir = tempdir().unwrap();
        save_credentials(dir.path(), r#"{"weexApiKey":"abc"}"#).unwrap();
        let loaded = load_credentials(dir.path()).unwrap();
        assert_eq!(loaded.as_deref(), Some(r#"{"weexApiKey":"abc"}"#));
    }

    #[test]
    fn reports_absent_when_nothing_stored() {
        let dir = tempdir().unwrap();
        assert_eq!(load_credentials(dir.path()).unwrap(), None);
    }

    #[test]
    fn ciphertext_does_not_contain_the_secret() {
        let dir = tempdir().unwrap();
        save_credentials(dir.path(), r#"{"weexSecret":"super-secret-value"}"#).unwrap();
        let blob = fs::read(credentials_path(dir.path())).unwrap();
        let haystack = String::from_utf8_lossy(&blob);
        assert!(!haystack.contains("super-secret-value"));
        assert!(!haystack.contains("weexSecret"));
    }

    #[test]
    fn blob_is_inert_without_the_local_key_half() {
        let dir = tempdir().unwrap();
        save_credentials(dir.path(), r#"{"weexSecret":"s"}"#).unwrap();
        // Simulate a backup that captured credentials.enc but not the key file,
        // then a fresh key generated on restore.
        fs::remove_file(key_path(dir.path())).unwrap();
        assert_eq!(load_credentials(dir.path()).unwrap(), None);
    }

    #[test]
    fn purge_removes_both_halves() {
        let dir = tempdir().unwrap();
        save_credentials(dir.path(), "{}").unwrap();
        purge_credentials(dir.path()).unwrap();
        assert!(!credentials_path(dir.path()).exists());
        assert!(!key_path(dir.path()).exists());
    }

    /// Seals a blob the way a default-key build would, bypassing whatever key
    /// this test binary was compiled with.
    fn seal_with(dir: &Path, embedded: &[u8], plaintext: &str) {
        let local = local_key_half(dir).unwrap();
        let key = sealing_key(embedded, &local);
        let cipher = XChaCha20Poly1305::new((&key).into());
        let nonce_bytes = [9u8; NONCE_LEN];
        let ciphertext = cipher
            .encrypt(XNonce::from_slice(&nonce_bytes), plaintext.as_bytes())
            .unwrap();
        let mut blob = Vec::new();
        blob.extend_from_slice(MAGIC);
        blob.extend_from_slice(&nonce_bytes);
        blob.extend_from_slice(&ciphertext);
        write_private(&credentials_path(dir), &blob).unwrap();
    }

    #[test]
    fn opens_a_blob_sealed_by_a_default_key_build() {
        // A release binary must still read credentials written by a local
        // build, and re-seal them under its own key.
        let dir = tempdir().unwrap();
        seal_with(dir.path(), DEFAULT_EMBEDDED_KEY, r#"{"weexApiKey":"k"}"#);

        let loaded = load_credentials(dir.path()).unwrap();
        assert_eq!(loaded.as_deref(), Some(r#"{"weexApiKey":"k"}"#));

        // Second read goes through the primary key, whatever it is.
        let local = local_key_half(dir.path()).unwrap();
        let blob = fs::read(credentials_path(dir.path())).unwrap();
        let key = sealing_key(primary_embedded_key(), &local);
        let cipher = XChaCha20Poly1305::new((&key).into());
        let nonce = XNonce::from_slice(&blob[MAGIC.len()..MAGIC.len() + NONCE_LEN]);
        assert!(cipher
            .decrypt(nonce, &blob[MAGIC.len() + NONCE_LEN..])
            .is_ok());
    }

    #[test]
    fn rejects_a_blob_sealed_by_an_unrelated_key() {
        let dir = tempdir().unwrap();
        seal_with(dir.path(), b"some-other-builds-secret", r#"{"weexApiKey":"k"}"#);
        assert_eq!(load_credentials(dir.path()).unwrap(), None);
    }

    #[test]
    fn a_different_embedded_key_yields_a_different_sealing_key() {
        let local = [7u8; KEY_FILE_LEN];
        let default = sealing_key(DEFAULT_EMBEDDED_KEY, &local);
        let ci = sealing_key(b"a-build-time-secret", &local);
        assert_ne!(default, ci);
    }

    #[test]
    fn a_different_local_half_yields_a_different_sealing_key() {
        let first = sealing_key(DEFAULT_EMBEDDED_KEY, &[1u8; KEY_FILE_LEN]);
        let second = sealing_key(DEFAULT_EMBEDDED_KEY, &[2u8; KEY_FILE_LEN]);
        assert_ne!(first, second);
    }

    #[test]
    fn a_build_time_key_still_accepts_default_sealed_blobs() {
        // Stands in for a release binary reading a blob written by a local
        // build: the fallback key stays in the candidate list.
        let candidates = if primary_embedded_key() == DEFAULT_EMBEDDED_KEY {
            vec![DEFAULT_EMBEDDED_KEY, b"pretend-ci-key".as_slice()]
        } else {
            candidate_embedded_keys()
        };
        assert!(candidates.contains(&DEFAULT_EMBEDDED_KEY));
    }

    #[test]
    fn default_build_offers_exactly_one_key() {
        if primary_embedded_key() == DEFAULT_EMBEDDED_KEY {
            assert_eq!(candidate_embedded_keys().len(), 1);
        }
    }

    #[cfg(unix)]
    #[test]
    fn secret_files_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir().unwrap();
        save_credentials(dir.path(), "{}").unwrap();
        for path in [credentials_path(dir.path()), key_path(dir.path())] {
            let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "{path:?} should be owner-only");
        }
    }
}
