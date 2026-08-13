import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  ApiClient({http.Client? client, FlutterSecureStorage? secureStorage})
    : _client = client ?? http.Client(),
      _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static String get baseUrl => _baseUrl;

  final http.Client _client;
  final FlutterSecureStorage _secureStorage;

  Future<void> signIn({
    required String email,
    required String password,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/v1/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    await _secureStorage.write(
      key: _accessTokenKey,
      value: body['access_token'] as String,
    );
    await _secureStorage.write(
      key: _refreshTokenKey,
      value: body['refresh_token'] as String,
    );
  }

  Future<bool> checkLibraryUpdate() async {
    final preferences = await SharedPreferences.getInstance();
    final release = preferences.getInt('library_release_no') ?? 0;
    final response = await _authorizedGet(
      '/v1/library/manifest?release=$release',
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final nextRelease = body['release_no'] as int;
    if (nextRelease > release) {
      await preferences.setInt('library_release_no', nextRelease);
    }
    return body['change'] != 'none';
  }

  Future<http.Response> _authorizedGet(String path) async {
    final token = await _secureStorage.read(key: _accessTokenKey);
    if (token == null) {
      throw const ApiException(401, 'Not signed in');
    }
    final response = await _client.get(
      Uri.parse('$_baseUrl$path'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, response.body);
    }
    return response;
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
}
