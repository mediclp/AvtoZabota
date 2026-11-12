// Правило «пора менять шины» по погоде — перенос avtozabota/core/weather.py.
// Здесь только чистая логика; загрузка из интернета — в lib/data/api.dart.
import 'models.dart';

const double thresholdC = 7.0;
const int stableDays = 5;
// Защита от аномалий: майское похолодание не повод ставить зимние, оттепель в январе — не повод снимать.
const winterSignalMonths = {8, 9, 10, 11, 12};
const summerSignalMonths = {2, 3, 4, 5, 6};

class DailyTemp {
  final DateTime on;
  final double meanC;
  final double minC;
  const DailyTemp(this.on, this.meanC, this.minC);

  Map<String, dynamic> toJson() => {'on': isoDate(on), 'mean': meanC, 'min': minC};
  factory DailyTemp.fromJson(Map<String, dynamic> j) =>
      DailyTemp(parseIsoDate(j['on'] as String), (j['mean'] as num).toDouble(), (j['min'] as num).toDouble());

  @override
  bool operator ==(Object other) => other is DailyTemp && other.on == on && other.meanC == meanC && other.minC == minC;
  @override
  int get hashCode => Object.hash(on, meanC, minC);
}

/// Ответ Open-Meteo → список дней. Дни без данных (null) пропускаются.
List<DailyTemp> parseOpenMeteo(Map<String, dynamic> payload) {
  final daily = payload['daily'] as Map<String, dynamic>;
  final times = daily['time'] as List;
  final means = daily['temperature_2m_mean'] as List;
  final mins = daily['temperature_2m_min'] as List;
  return [
    for (var i = 0; i < times.length; i++)
      if (means[i] != null && mins[i] != null)
        DailyTemp(parseIsoDate(times[i] as String), (means[i] as num).toDouble(), (mins[i] as num).toDouble()),
  ];
}

bool _fits(DailyTemp d, TireSeason target) =>
    target == TireSeason.winter ? d.meanC <= thresholdC : d.meanC >= thresholdC && d.minC >= 0;

/// Первый день серии из [stableDays] дней подряд, когда погода требует комплект [target].
/// [notBefore] — отбросить дни раньше этой даты (например, до прошлой смены шин).
DateTime? swapSignal(List<DailyTemp> temps, TireSeason target, {DateTime? notBefore}) {
  final months = target == TireSeason.winter ? winterSignalMonths : summerSignalMonths;
  final days = [for (final d in temps) if (notBefore == null || !d.on.isBefore(notBefore)) d]
    ..sort((a, b) => a.on.compareTo(b.on));
  DateTime? runStart;
  DateTime? prev;
  var runLen = 0;
  for (final d in days) {
    final contiguous = prev != null && daysBetween(prev, d.on) == 1;
    if (_fits(d, target)) {
      if (!contiguous || runLen == 0) {
        runStart = d.on;
        runLen = 0;
      }
      runLen++;
      if (runLen >= stableDays && months.contains(runStart!.month)) return runStart;
    } else {
      runLen = 0;
    }
    prev = d.on;
  }
  return null;
}

/// Прогноз свежий: в нём есть сегодняшний день или позже.
bool covers(List<DailyTemp> temps, DateTime today) => temps.any((d) => !d.on.isBefore(today));
