/// Client for the engine's local HTTP API.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class EngineApi {
  EngineApi({this.baseUrl = 'http://127.0.0.1:9124', this.token = ''});

  final String baseUrl;
  final String token;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token.isNotEmpty) 'authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> getJson(String path) async {
    final resp = await http.get(Uri.parse('$baseUrl$path'), headers: _headers);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(String path) async {
    final resp = await http.get(Uri.parse('$baseUrl$path'), headers: _headers);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as List;
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final resp = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> health() => getJson('/health');
  Future<Map<String, dynamic>> status() => getJson('/status');
  Future<List<dynamic>> inputs() => getList('/inputs');
  Future<Map<String, dynamic>> kill() => getJson('/kill');
}
