// Выбор города — перенос avtozabota/core/cities.py.
// Файл: assets/data/cities.json. Онлайн-поиск — в lib/data/api.dart.
import 'dart:convert';

import 'models.dart';

class City {
  final String name;
  final String region; // для подписи: «Самара, Самарская область»
  final double lat;
  final double lon;
  final int? population;
  const City(this.name, this.region, this.lat, this.lon, [this.population]);

  String get title => region.isEmpty ? name : '$name, $region';
  String get climateZone => zoneFor(lat, lon);
}

/// Климатическая зона по координатам (id из climateZones в tires.dart).
///   south      — южнее 47.5° и западнее 50° в.д.: Крым, Кубань, Ростов, Ставрополь, Кавказ, Астрахань;
///   north_east — восточнее 55° в.д. (Урал, Сибирь, Дальний Восток) или севернее 61° (Север);
///   center     — всё остальное.
String zoneFor(double lat, double lon) {
  if (lat >= 61 || lon >= 55) return 'north_east';
  if (lat < 47.5 && lon < 50) return 'south';
  return 'center';
}

/// Географическая рамка, для которой рассчитаны климатические зоны (Россия с запасом).
/// Отсекает тёзок вроде «Сочи» в Мексике или «Казан» в Турции.
bool inServiceArea(double lat, double lon) => lat >= 41 && lat <= 82 && (lon >= 19 || lon <= -168);

String _norm(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll('-', ' ').trim();

List<City> parseCities(String jsonText) {
  final raw = jsonDecode(jsonText) as Map<String, dynamic>;
  return [
    for (final c in raw['cities'] as List)
      City(c['name'] as String, c['region'] as String, (c['lat'] as num).toDouble(), (c['lon'] as num).toDouble(),
          c['population'] as int?),
  ];
}

/// Поиск во встроенном списке: сначала совпадения с начала названия, затем по подстроке;
/// внутри — крупные города выше. «орел» находит «Орёл», «ростов на» — «Ростов-на-Дону».
List<City> searchCities(String query, List<City> cities, {int limit = 10}) {
  final q = _norm(query);
  if (q.isEmpty) return [];
  int byPop(City a, City b) => (b.population ?? 0).compareTo(a.population ?? 0);
  final starts = [for (final c in cities) if (_norm(c.name).startsWith(q)) c]..sort(byPop);
  final contains = [for (final c in cities) if (_norm(c.name).contains(q) && !starts.contains(c)) c]..sort(byPop);
  return [...starts, ...contains].take(limit).toList();
}

/// Ответ геокодера Open-Meteo → населённые пункты в рамке [inServiceArea], крупные первыми
/// (мысы, аэропорты и т. п. отброшены). Подпись — регион (admin1) как есть, иногда латиницей.
List<City> parseGeocoding(Map<String, dynamic> payload) {
  final result = <City>[
    for (final r in payload['results'] as List? ?? const [])
      if ((r['feature_code'] as String? ?? 'PPL').startsWith('PPL') &&
          inServiceArea((r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble()))
        City(r['name'] as String, (r['admin1'] ?? '') as String, (r['latitude'] as num).toDouble(),
            (r['longitude'] as num).toDouble(), r['population'] as int?),
  ];
  result.sort((a, b) => (b.population ?? 0).compareTo(a.population ?? 0));
  return result;
}

double _round2(double v) => (v * 100).round() / 100;

/// Привязать машину к городу: координаты для прогноза и климатическая зона для календаря.
void applyCity(Car car, City city) {
  car.city = city.title;
  car.location = (_round2(city.lat), _round2(city.lon));
  car.climateZone = city.climateZone;
}
