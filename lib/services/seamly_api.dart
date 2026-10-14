import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SeamlyApi {
  SeamlyApi({http.Client? client}) : _client = client ?? http.Client();

  static const _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  final http.Client _client;

  Future<Map<String, dynamic>> registerAccount({
    required String name,
    required String email,
    required String password,
    required double heightCm,
    String? phone,
    String? location,
  }) {
    return _post('/v1/auth/register', {
      'name': name.trim(),
      'email': email.trim(),
      'password': password,
      'height_cm': heightCm,
      if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      if (location != null && location.trim().isNotEmpty)
        'location': location.trim(),
    });
  }

  Future<Map<String, dynamic>> loginAccount({
    required String email,
    required String password,
  }) {
    return _post('/v1/auth/login', {
      'email': email.trim(),
      'password': password,
    });
  }

  Future<Map<String, dynamic>> loginWithGoogle({required String idToken}) {
    return _post('/v1/auth/google', {'id_token': idToken});
  }

  Future<Map<String, dynamic>> fetchAccountProfile({required String token}) {
    return _get('/v1/account/profile', const {}, token: token);
  }

  Future<Map<String, dynamic>> updateAccountProfile({
    required String token,
    required String name,
    required double heightCm,
    String? avatarBase64,
    bool updateAvatar = false,
  }) {
    return _put('/v1/account/profile', {
      'name': name.trim(),
      'height_cm': heightCm,
      if (updateAvatar) 'avatar_base64': avatarBase64,
    }, token: token);
  }

  Future<void> logoutAccount({required String token}) async {
    await _post(
      '/v1/auth/logout',
      const {},
      token: token,
      timeout: const Duration(seconds: 15),
    );
  }

  Future<Map<String, dynamic>> saveAccountMeasurements({
    required String token,
    required Map<String, double> measurements,
    String? sizeLabel,
    double? scanConfidence,
  }) {
    return _put('/v1/account/measurements', {
      'measurements': measurements,
      if (sizeLabel != null && sizeLabel.isNotEmpty) 'size_label': sizeLabel,
      'scan_confidence': ?scanConfidence,
    }, token: token);
  }

  Future<Map<String, dynamic>> recommendSize({
    required Map<String, double> measurements,
    required String fitPreference,
  }) {
    return _post('/v1/size/recommend', {
      'measurements': measurements,
      'fit_preference': fitPreference,
    });
  }

  Future<Map<String, dynamic>> analyzeColor({
    required String skinHex,
    required String hairHex,
    required String eyeHex,
  }) {
    return _post('/v1/color/analyze', {
      'skin_hex': skinHex,
      'hair_hex': hairHex,
      'eye_hex': eyeHex,
    });
  }

  /// Guided scan: sends only the widths and depths measured on the phone
  /// (the output of `BodyProfile.toJson()`), never a photo.
  Future<Map<String, dynamic>> analyzeBodyProfile(
    Map<String, dynamic> profileJson,
  ) {
    return _post('/v1/body-scan/profile', {
      ...profileJson,
      'consent_confirmed': true,
    }, timeout: const Duration(seconds: 30));
  }

  Future<Map<String, dynamic>> analyzeAppearancePhoto({
    required Uint8List imageBytes,
  }) {
    return _post('/v1/profile/analyze', {
      'image_base64': base64Encode(imageBytes),
      'consent_confirmed': true,
    }, timeout: const Duration(seconds: 90));
  }

  /// Selfie color scan: sends only colors sampled on the phone over several
  /// frames (see `SelfieSample.toJson`), never a photo.
  Future<Map<String, dynamic>> analyzeColorFrames(
    List<Map<String, dynamic>> frames,
  ) {
    return _post('/v1/profile/analyze-frames', {
      'frames': frames,
      'consent_confirmed': true,
    }, timeout: const Duration(seconds: 30));
  }

  Future<Map<String, dynamic>> fetchFashionNews({
    required String category,
    int limit = 16,
  }) {
    return _get('/v1/news/feed', {
      'category': category,
      'limit': '$limit',
    }, timeout: const Duration(seconds: 75));
  }

  Future<Map<String, dynamic>> fetchHomeWeather({
    required String city,
    String? sizeLabel,
    String? colorSeason,
  }) {
    return _get('/v1/weather/home', {
      'city': city,
      if (sizeLabel != null && sizeLabel.isNotEmpty) 'size_label': sizeLabel,
      if (colorSeason != null && colorSeason.isNotEmpty)
        'color_season': colorSeason,
    }, timeout: const Duration(seconds: 75));
  }

  Future<Map<String, dynamic>> fetchShopProducts({int limit = 40}) {
    return _get('/v1/shop/products', {
      'limit': '$limit',
    }, timeout: const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> recommendStyle({
    required String climate,
    required String hemisphere,
    required int month,
    required String occasion,
    required String style,
    required String colorSeason,
    String? sizeLabel,
  }) {
    return _post('/v1/style/recommend', {
      'climate': climate,
      'hemisphere': hemisphere,
      'month': month,
      'occasion': occasion,
      'style': style,
      'color_season': colorSeason,
      if (sizeLabel != null && sizeLabel.isNotEmpty) 'size_label': sizeLabel,
    });
  }

  Future<Map<String, dynamic>> planEventOutfit({
    required String eventText,
    required String city,
    required String eventDate,
    String? eventTime,
    String? style,
    String? sizeLabel,
    String? colorSeason,
    Map<String, double>? measurements,
  }) {
    return _post('/v1/outfits/plan', {
      'event_text': eventText.trim(),
      'city': city,
      'event_date': eventDate,
      if (eventTime != null && eventTime.isNotEmpty) 'event_time': eventTime,
      if (style != null && style.isNotEmpty) 'style': style,
      if (sizeLabel != null && sizeLabel.isNotEmpty) 'size_label': sizeLabel,
      if (colorSeason != null && colorSeason.isNotEmpty)
        'color_season': colorSeason,
      if (measurements != null && measurements.isNotEmpty)
        'measurements': measurements,
    }, timeout: const Duration(seconds: 90));
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 75),
    String? token,
  }) async {
    late http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_configuredBaseUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on Exception {
      throw const ApiException(
        'The styling service is temporarily unavailable. Check your internet connection and try again.',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(_humanizeError(detail));
    }
    return decoded as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> queryParameters, {
    Duration timeout = const Duration(seconds: 75),
    String? token,
  }) async {
    late http.Response response;
    try {
      final uri = Uri.parse(
        '$_configuredBaseUrl$path',
      ).replace(queryParameters: queryParameters);
      response = await _client
          .get(
            uri,
            headers: {if (token != null) 'Authorization': 'Bearer $token'},
          )
          .timeout(timeout);
    } on Exception {
      throw const ApiException(
        'The live service is temporarily unavailable. Check your internet connection and try again.',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(_humanizeError(detail));
    }
    return decoded as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> payload, {
    required String token,
    Duration timeout = const Duration(seconds: 75),
  }) async {
    late http.Response response;
    try {
      response = await _client
          .put(
            Uri.parse('$_configuredBaseUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on Exception {
      throw const ApiException(
        'Your profile could not be saved right now. Check your connection and try again.',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(_humanizeError(detail));
    }
    return decoded as Map<String, dynamic>;
  }

  String _humanizeError(dynamic detail) {
    if (detail is List && detail.isNotEmpty && detail.first is Map) {
      return detail.first['msg']?.toString() ??
          'Please review the information and try again.';
    }
    return detail?.toString() ?? 'Something went wrong. Please try again.';
  }
}
