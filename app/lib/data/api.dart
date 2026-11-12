// Запросы в интернет: прогноз погоды и поиск города (Open-Meteo, без ключа).
// Логика разбора ответов — в core (parseOpenMeteo, parseGeocoding), здесь только HTTP.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/cities.dart';
import '../core/weather.dart';

const _forecastUrl = 'https://api.open-meteo.com/v1/forecast';
const _geocodingUrl = 'https://geocoding-api.open-meteo.com/v1/search';
const _timeout = Duration(seconds: 15);

/// 7 прошедших дней + 16 дней прогноза. Бросает исключение при сбое — тогда считаем по календарю.
Future<List<DailyTemp>> fetchDailyTemps(double lat, double lon, {http.Client? client}) async {
  final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
    'latitude': lat.toStringAsFixed(2), // ~1 км: точнее не нужно, и точный адрес не уходит в сервис
    'longitude': lon.toStringAsFixed(2),
    'daily': 'temperature_2m_mean,temperature_2m_min',
    'timezone': 'auto',
    'past_days': '7',
    'forecast_days': '16',
  });
  final resp = await (client ?? http.Client()).get(uri).timeout(_timeout);
  if (resp.statusCode != 200) throw http.ClientException('Open-Meteo: HTTP ${resp.statusCode}', uri);
  return parseOpenMeteo(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
}

/// Поиск любого населённого пункта.
Future<List<City>> searchOnline(String query, {http.Client? client}) async {
  final q = query.trim();
  if (q.length < 2) return [];
  final uri = Uri.parse(_geocodingUrl).replace(queryParameters: {
    'name': q,
    'count': '10',
    'language': 'ru',
    'format': 'json',
  });
  final resp = await (client ?? http.Client()).get(uri).timeout(_timeout);
  if (resp.statusCode != 200) throw http.ClientException('Геокодер: HTTP ${resp.statusCode}', uri);
  return parseGeocoding(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
}
