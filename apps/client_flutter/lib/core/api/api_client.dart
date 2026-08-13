/// Shared API error type used across the client.
class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
}

/// Server base URL, injected at build time via `--dart-define=API_BASE_URL=...`.
///
/// The old ApiClient wrapper that used to live in this file duplicated
/// TrainingRepository's HTTP logic and was removed; only the shared pieces
/// remain here.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
