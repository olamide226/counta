import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../domain/counting/block_service.dart';

/// Talks to the `voice-block` Supabase Edge Function, and is the only thing
/// that does.
///
/// Every documented status becomes a [BlockFailure] subtype; nothing from
/// `package:http` and no bare [Exception] escapes. See `supabase/README.md`
/// for the contract this implements.
class BlockClient implements BlockService {
  BlockClient({
    required Uri functionUrl,
    required Future<String?> Function() accessToken,
    String? anonKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _functionUrl = functionUrl,
       _accessToken = accessToken,
       _anonKey = anonKey,
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Base URL of the function, e.g. `https://<ref>.supabase.co/functions/v1/voice-block`.
  final Uri _functionUrl;

  /// Supplies the caller's Supabase JWT. Read per request rather than captured
  /// once, because the SDK refreshes it under us during a long session.
  final Future<String?> Function() _accessToken;

  /// Publishable key, sent as `apikey`. The Supabase gateway wants it even for
  /// a function that verifies JWTs itself.
  final String? _anonKey;

  final http.Client _http;
  final bool _ownsClient;

  /// Cap on a single request. A session start blocked on a hung socket is
  /// worse than one that fails fast and says so.
  final Duration timeout;

  @override
  Future<VoiceBlock> acquire(String sessionId) async {
    final body = await _post(_functionUrl, {'session_id': sessionId});

    switch (body.status) {
      case 200:
        return _blockFrom(body.json, body.status);
      case 402:
        final balance = _asInt(body.json['balance']) ?? 0;
        final required = _asInt(body.json['required']) ?? 0;
        throw BlockInsufficientCredit(balance: balance, required: required);
      case 409:
        throw BlockInFlight(expiresAt: _asDate(body.json['expires_at']));
      default:
        throw _commonFailure(body);
    }
  }

  @override
  Future<String> refreshToken(String blockId) async {
    final body = await _post(_tokenUrl, {'block_id': blockId});
    if (body.status != 200) throw _commonFailure(body);

    final token = body.json['token'];
    if (token is! String || token.isEmpty) {
      // A 200 that carries no token is not something to retry or explain away.
      throw BlockUnreachable(
        FormatException('voice-block returned an unusable token: ${body.json}'),
      );
    }
    return token;
  }

  @override
  Future<BlockRelease> release(
    String blockId, {
    required int streamedSecs,
    required int detections,
    required bool eligibleForRefund,
  }) async {
    final body = await _post(_releaseUrl, {
      'block_id': blockId,
      // Both counts are clamped rather than sent negative: the server answers
      // 400 to anything that is not a non-negative integer, and a release that
      // 400s reports no usage at all.
      'streamed_secs': streamedSecs < 0 ? 0 : streamedSecs,
      'detections': detections < 0 ? 0 : detections,
      'eligible_for_refund': eligibleForRefund,
    });

    if (body.status != 200) throw _commonFailure(body);

    return BlockRelease(
      refunded: body.json['refunded'] == true,
      balance: _asInt(body.json['balance']),
    );
  }

  Uri get _releaseUrl =>
      _functionUrl.replace(path: '${_functionUrl.path}/release');

  Uri get _tokenUrl => _functionUrl.replace(path: '${_functionUrl.path}/token');

  VoiceBlock _blockFrom(Map<String, dynamic> json, int status) {
    final id = json['block_id'];
    final token = json['token'];
    final seconds = _asInt(json['block_seconds']);
    final expiresAt = _asDate(json['expires_at']);
    if (id is! String || token is! String || seconds == null) {
      // A 200 that is not a grant is not something to retry or explain away.
      throw BlockUnreachable(
        FormatException('voice-block returned an unusable grant: $json'),
      );
    }
    return VoiceBlock(
      id: id,
      deepgramToken: token,
      blockSeconds: seconds,
      // Falling back to a locally derived expiry keeps the renewal clock
      // running even if the server omits the field; block_seconds is what the
      // timing actually depends on.
      expiresAt: expiresAt ?? DateTime.now().add(Duration(seconds: seconds)),
      balanceAfter: _asInt(json['balance_after']) ?? 0,
    );
  }

  /// The statuses that mean the same thing on every endpoint.
  BlockFailure _commonFailure(_Body body) {
    final reason = body.json['error'];
    switch (body.status) {
      case 401:
        return const BlockUnauthenticated();
      case 404:
        return const BlockNotFound();
      case 429:
        return BlockRateLimited(retryAfter: body.retryAfter);
      case 503:
        return const BlockProviderUnavailable();
      default:
        return BlockRequestRejected(
          status: body.status,
          reason: reason is String ? reason : 'unexpected_status',
        );
    }
  }

  Future<_Body> _post(Uri url, Map<String, dynamic> payload) async {
    final token = await _accessToken();
    if (token == null || token.isEmpty) {
      // The function would answer 401 anyway; saying so without the round trip
      // keeps a signed-out build from hammering it.
      throw const BlockUnauthenticated();
    }

    http.Response response;
    try {
      response = await _http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              if (_anonKey != null) 'apikey': _anonKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } catch (error) {
      throw BlockUnreachable(error);
    }

    Map<String, dynamic> json;
    try {
      final decoded = response.body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(response.body);
      json = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      json = const {};
    }
    return _Body(response.statusCode, json, _retryAfterOf(response, json));
  }

  /// How long the server wants us to wait, read from wherever it said so.
  ///
  /// Two places state it and either may be the only one: the Supabase gateway
  /// rate-limits with the standard `Retry-After` header, while the function
  /// states its own window in the body alongside every other field of its
  /// contract. Reading only the header left [BlockRateLimited.retryAfter]
  /// permanently null against the function's own 429, so the engine always
  /// fell back to its hard-coded delay and came back inside the window it had
  /// just been refused in.
  static Duration? _retryAfterOf(
    http.Response response,
    Map<String, dynamic> json,
  ) {
    final header = response.headers['retry-after']?.trim();
    final seconds =
        (header == null ? null : int.tryParse(header)) ??
        _asInt(json['retry_after']);
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  static int? _asInt(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  static DateTime? _asDate(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  @override
  Future<void> dispose() async {
    if (_ownsClient) _http.close();
  }
}

class _Body {
  const _Body(this.status, this.json, this.retryAfter);

  final int status;
  final Map<String, dynamic> json;
  final Duration? retryAfter;
}
