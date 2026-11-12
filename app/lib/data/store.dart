// Хранилище приложения: машины пользователя, справочники и кэш прогноза погоды.
//
// Данные лежат на телефоне в SharedPreferences одной JSON-строкой (для MVP с парой
// машин этого достаточно; если записей станет много — перейти на SQLite).
// Экраны подписываются на изменения через ListenableBuilder.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cities.dart';
import '../core/models.dart';
import '../core/notification_plan.dart';
import '../core/regulations.dart';
import '../core/schedule.dart';
import '../core/weather.dart';
import 'api.dart' as api;
import 'notifications.dart';

const _carsKey = 'cars_v1';
const _forecastsKey = 'forecasts_v1';
const _notifyEnabledKey = 'notify_enabled';
const _notifyTimeKey = 'notify_time';
const _notifyLateKey = 'notify_late_today';

class CachedForecast {
  final DateTime fetchedOn;
  final List<DailyTemp> temps;
  const CachedForecast(this.fetchedOn, this.temps);

  Map<String, dynamic> toJson() => {'fetched_on': isoDate(fetchedOn), 'temps': [for (final t in temps) t.toJson()]};
  factory CachedForecast.fromJson(Map<String, dynamic> j) => CachedForecast(
        parseIsoDate(j['fetched_on'] as String),
        [for (final t in j['temps'] as List) DailyTemp.fromJson(t as Map<String, dynamic>)],
      );
}

/// Напоминание для списка «Ближайшие напоминания».
class UpcomingReminder {
  final DateTime on;
  final Car car;
  final ScheduleItem item;
  const UpcomingReminder(this.on, this.car, this.item);
}

class AppStore extends ChangeNotifier {
  AppStore._(this._prefs, this.regulations, this.cities, this._cars, this._forecasts, this._clock, this.notifier);

  final SharedPreferences _prefs;
  final Map<String, Regulation> regulations;
  final List<City> cities;
  final List<Car> _cars;
  final Map<String, CachedForecast> _forecasts; // ключ — координаты «lat,lon»: у машин в одном городе общий
  final DateTime Function() _clock;
  final Notifier notifier;

  static Future<AppStore> load({DateTime Function()? clock, Notifier? notifier}) async {
    final prefs = await SharedPreferences.getInstance();
    final regs = parseRegulations(await rootBundle.loadString('assets/data/regulations.json'));
    final cities = parseCities(await rootBundle.loadString('assets/data/cities.json'));
    final carsJson = prefs.getString(_carsKey);
    final cars = carsJson == null
        ? <Car>[]
        : [for (final c in jsonDecode(carsJson) as List) Car.fromJson(c as Map<String, dynamic>)];
    final fJson = prefs.getString(_forecastsKey);
    final forecasts = fJson == null
        ? <String, CachedForecast>{}
        : {
            for (final e in (jsonDecode(fJson) as Map<String, dynamic>).entries)
              e.key: CachedForecast.fromJson(e.value as Map<String, dynamic>),
          };
    final n = notifier ?? LocalNotifier();
    await n.init();
    return AppStore._(prefs, regs, cities, cars, forecasts, clock ?? DateTime.now, n);
  }

  /// Вызывается после запуска приложения: обновить прогноз и перепланировать уведомления.
  Future<void> start() async {
    await rescheduleNotifications();
    await refreshForecasts();
  }

  DateTime get today => dateOnly(_clock());
  List<Car> get cars => List.unmodifiable(_cars);
  Map<String, List<String>> get modelCatalog => catalog(regulations);

  Car? carById(String id) {
    for (final c in _cars) {
      if (c.id == id) return c;
    }
    return null;
  }

  Regulation regulationFor(Car car) => regulations[car.regulationId] ?? regulations[genericId]!;

  // ---------- изменения (каждое сохраняется и оповещает экраны) ----------

  Future<void> addCar(Car car) async {
    _cars.add(car);
    await _save();
    refreshForecasts(); // без await: прогноз догрузится в фоне
  }

  Future<void> deleteCar(Car car) async {
    _cars.removeWhere((c) => c.id == car.id);
    await _save();
  }

  /// Бросает ArgumentError, если пробег меньше уже записанного.
  Future<void> addReading(Car car, int km) async {
    car.addReading(OdometerReading(today, km));
    await _save();
  }

  /// Бросает ArgumentError при некорректных данных (пробег, шины без расходника «Шины»).
  Future<void> addService(Car car, ServiceRecord record) async {
    car.addService(record);
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(_carsKey, jsonEncode([for (final c in _cars) c.toJson()]));
    notifyListeners();
    await rescheduleNotifications();
  }

  // ---------- уведомления ----------

  bool get notificationsEnabled => _prefs.getBool(_notifyEnabledKey) ?? false;

  /// Время уведомлений (часы, минуты); по умолчанию 10:00.
  (int, int) get notifyTime {
    final parts = (_prefs.getString(_notifyTimeKey) ?? '10:00').split(':');
    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  bool get canScheduleNotifications => notifier.canSchedule;

  /// Включить: спрашивает разрешение. Возвращает false, если пользователь не разрешил.
  Future<bool> setNotificationsEnabled(bool enabled) async {
    if (enabled && !await notifier.requestPermission()) return false;
    await _prefs.setBool(_notifyEnabledKey, enabled);
    notifyListeners();
    await rescheduleNotifications();
    return true;
  }

  Future<void> setNotifyTime(int hour, int minute) async {
    await _prefs.setString(_notifyTimeKey, '$hour:$minute');
    notifyListeners();
    await rescheduleNotifications();
  }

  Future<void> sendTestNotification() => notifier.showTest(
      'АвтоЗабота', 'Уведомления работают. Напомним о ТО заранее — в ${_fmtTime(notifyTime)}.');

  static String _fmtTime((int, int) t) => '${t.$1}:${t.$2.toString().padLeft(2, '0')}';

  /// План, который сейчас стоит на телефоне (для экрана напоминаний).
  List<PlannedNotification> get plannedNotifications => _lastPlan;
  List<PlannedNotification> _lastPlan = const [];

  /// Отменить все отложенные уведомления и поставить заново по текущему графику.
  Future<void> rescheduleNotifications() async {
    if (!notificationsEnabled) {
      _lastPlan = const [];
      await notifier.reschedule(const []);
      return;
    }
    final now = _clock();
    final todayIso = isoDate(dateOnly(now));
    // «Опоздавшие» сегодняшние напоминания: ключ → на какое время поставили. Храним до конца дня.
    final lateJson = _prefs.getString(_notifyLateKey);
    final late = <String, DateTime>{};
    if (lateJson != null) {
      final m = jsonDecode(lateJson) as Map<String, dynamic>;
      if (m['date'] == todayIso) {
        for (final e in (m['at'] as Map<String, dynamic>).entries) {
          late[e.key] = DateTime.parse(e.value as String);
        }
      }
    }
    final (h, mi) = notifyTime;
    final plan = planNotifications([for (final c in _cars) (c, scheduleFor(c))], now,
        hour: h, minute: mi, lateToday: late);
    for (final p in plan) {
      if (p.lateToday) late[p.key] = p.at;
    }
    await _prefs.setString(_notifyLateKey,
        jsonEncode({'date': todayIso, 'at': {for (final e in late.entries) e.key: e.value.toIso8601String()}}));
    _lastPlan = plan;
    try {
      await notifier.reschedule(plan);
    } catch (e) {
      debugPrint('Не удалось запланировать уведомления: $e');
    }
  }

  // ---------- график и напоминания ----------

  CachedForecast? forecastFor(Car car) {
    final loc = car.location;
    return loc == null ? null : _forecasts[_locKey(loc)];
  }

  List<ScheduleItem> scheduleFor(Car car) =>
      buildSchedule(car, regulationFor(car), today, forecast: forecastFor(car)?.temps);

  /// Худший статус машины — для значка в списке машин.
  Status worstStatus(Car car) {
    final items = scheduleFor(car);
    return items.isEmpty ? Status.ok : items.first.status; // график уже отсортирован по важности
  }

  List<UpcomingReminder> upcomingReminders({int days = 60}) {
    final until = addDays(today, days);
    final result = <UpcomingReminder>[
      for (final car in _cars)
        for (final item in scheduleFor(car))
          for (final r in item.reminders)
            if (!r.isAfter(until)) UpcomingReminder(r, car, item),
    ];
    result.sort((a, b) => a.on.compareTo(b.on));
    return result;
  }

  // ---------- прогноз погоды ----------

  static String _locKey((double, double) loc) => '${loc.$1.toStringAsFixed(2)},${loc.$2.toStringAsFixed(2)}';

  /// Раз в день обновляет прогноз для городов машин. Ошибки сети не страшны — тогда расчёт по календарю.
  Future<void> refreshForecasts({bool force = false}) async {
    var changed = false;
    final locations = {for (final c in _cars) if (c.location != null) _locKey(c.location!): c.location!};
    for (final e in locations.entries) {
      final cached = _forecasts[e.key];
      if (!force && cached != null && cached.fetchedOn == today) continue;
      try {
        _forecasts[e.key] = CachedForecast(today, await api.fetchDailyTemps(e.value.$1, e.value.$2));
        changed = true;
      } catch (err) {
        debugPrint('Прогноз для ${e.key} не загрузился: $err');
      }
    }
    if (changed) {
      await _prefs.setString(_forecastsKey, jsonEncode({for (final e in _forecasts.entries) e.key: e.value.toJson()}));
      notifyListeners();
      await rescheduleNotifications(); // срок смены шин мог сдвинуться по новому прогнозу
    }
  }
}
