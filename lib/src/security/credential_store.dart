import 'dart:convert';

import '../bridge/api.dart' as rust;

/// Where WEEX and Telegram credentials live between runs.
///
/// Credentials used to sit beside every other setting in
/// `shared_preferences.json` as plain JSON. They now go through this interface
/// so that the only production implementation is the encrypted one.
abstract class CredentialStore {
  Future<Map<String, Object?>?> read();

  Future<void> write(Map<String, Object?> credentials);

  Future<void> purge();
}

/// Production store: hands the credentials to Rust, which seals them into
/// `credentials.enc` under the app data directory.
///
/// Failures are swallowed into "no credentials" rather than thrown. A user who
/// cannot decrypt should be asked to re-enter their keys, not met with a
/// crashed app — and `errors` records what happened for the caller to log.
class EncryptedCredentialStore implements CredentialStore {
  EncryptedCredentialStore(this.directory);

  final String directory;

  /// Reasons the last operation failed, for the caller to surface in the log.
  final List<String> errors = [];

  @override
  Future<Map<String, Object?>?> read() async {
    errors.clear();
    try {
      final result = await rust.secretsLoad(dir: directory);
      if (!result.ok) {
        errors.add(result.error ?? 'unknown error');
        return null;
      }
      final raw = result.value;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } catch (error) {
      errors.add(error.toString());
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?> credentials) async {
    errors.clear();
    try {
      final result = await rust.secretsSave(
        dir: directory,
        credentialsJson: jsonEncode(credentials),
      );
      if (!result.ok) {
        errors.add(result.error ?? 'unknown error');
      }
    } catch (error) {
      errors.add(error.toString());
    }
  }

  @override
  Future<void> purge() async {
    errors.clear();
    try {
      await rust.secretsPurge(dir: directory);
    } catch (error) {
      errors.add(error.toString());
    }
  }

  /// Tightens permissions on the data directory and the secrets in it.
  Future<void> harden() async {
    try {
      await rust.secretsHarden(dir: directory);
    } catch (error) {
      errors.add(error.toString());
    }
  }
}

/// Test store. Keeps credentials in memory for the lifetime of the object, so
/// tests can exercise persistence without ever writing a secret to disk.
class InMemoryCredentialStore implements CredentialStore {
  Map<String, Object?>? _credentials;

  @override
  Future<Map<String, Object?>?> read() async => _credentials;

  @override
  Future<void> write(Map<String, Object?> credentials) async {
    _credentials = Map<String, Object?>.from(credentials);
  }

  @override
  Future<void> purge() async {
    _credentials = null;
  }
}
