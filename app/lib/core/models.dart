// Модель данных АвтоЗаботы — перенос avtozabota/core/models.py.
//
// Все даты — «только дата» в UTC (без времени), чтобы разница в днях не
// ломалась на переходах на летнее время. Создавайте их через [day] или [dateOnly].

/// Дата без времени.
DateTime day(int year, int month, int d) => DateTime.utc(year, month, d);
DateTime dateOnly(DateTime t) => DateTime.utc(t.year, t.month, t.day);
int daysBetween(DateTime from, DateTime to) => to.difference(from).inDays;
DateTime addDays(DateTime d, int n) => d.add(Duration(days: n));
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime parseIsoDate(String s) => dateOnly(DateTime.parse(s));

T _byId<T extends Enum>(List<T> values, String id, String Function(T) getId, String what) =>
    values.firstWhere((v) => getId(v) == id, orElse: () => throw FormatException('Неизвестный $what: $id'));

enum Consumable {
  engineOil('engine_oil', 'Моторное масло и масляный фильтр'),
  airFilter('air_filter', 'Воздушный фильтр'),
  cabinFilter('cabin_filter', 'Салонный фильтр'),
  brakePads('brake_pads', 'Тормозные колодки'),
  brakeFluid('brake_fluid', 'Тормозная жидкость'),
  sparkPlugs('spark_plugs', 'Свечи зажигания'),
  tires('tires', 'Шины');

  const Consumable(this.id, this.title);
  final String id;
  final String title;
  static Consumable fromId(String id) => _byId(values, id, (v) => v.id, 'расходник');
}

/// Что делать с расходником. (Не `Action`: так называется класс во Flutter.)
enum ServiceAction {
  replace('replace', 'Заменить'),
  inspect('inspect', 'Проверить'),
  seasonalSwap('seasonal_swap', 'Сменить шины');

  const ServiceAction(this.id, this.title);
  final String id;
  final String title;
  static ServiceAction fromId(String id) => _byId(values, id, (v) => v.id, 'действие');
}

enum TireSetup {
  seasonal('seasonal', 'Летние + зимние'),
  allSeason('all_season', 'Всесезонные');

  const TireSetup(this.id, this.title);
  final String id;
  final String title;
  static TireSetup fromId(String id) => _byId(values, id, (v) => v.id, 'тип шин');
}

enum TireSeason {
  summer('summer', 'Летние'),
  winter('winter', 'Зимние');

  const TireSeason(this.id, this.title);
  final String id;
  final String title;
  static TireSeason fromId(String id) => _byId(values, id, (v) => v.id, 'сезон шин');
}

// ---------- Справочник (только чтение) ----------

class RegulationItem {
  final Consumable consumable;
  final ServiceAction action;
  final int? intervalKm;
  final int? intervalMonths;
  final bool sourced; // интервал взят из источника, а не подставлен по умолчанию
  final String note;

  /// Отличия для двигателей. Сам пункт — вариант «двигатель не указан» (самый частый интервал).
  final Map<String, RegulationItem> byEngine;

  RegulationItem({
    required this.consumable,
    required this.action,
    this.intervalKm,
    this.intervalMonths,
    this.sourced = false,
    this.note = '',
    this.byEngine = const {},
  }) {
    if (intervalKm == null && intervalMonths == null) {
      throw ArgumentError('${consumable.id}: нужен интервал в км или в месяцах');
    }
    for (final v in [intervalKm, intervalMonths]) {
      if (v != null && v <= 0) throw ArgumentError('${consumable.id}: интервал должен быть > 0');
    }
    for (final o in byEngine.values) {
      if (o.consumable != consumable || o.action != action) {
        throw ArgumentError('${consumable.id}: вариант для двигателя — другой расходник');
      }
    }
  }

  RegulationItem forEngine(String? engineId) => byEngine[engineId] ?? this;
}

class Engine {
  final String id; // "2.0_mpi"
  final String title; // "2.0 MPI (атмосферный)"
  const Engine(this.id, this.title);
}

class Regulation {
  final String id;
  final String make; // "*" — общий регламент
  final String model;
  final int? yearFrom;
  final int? yearTo;
  final List<RegulationItem> items;
  final String source;
  final List<Engine> engines; // пусто — двигатель не влияет, не спрашиваем

  Regulation({
    required this.id,
    required this.make,
    required this.model,
    this.yearFrom,
    this.yearTo,
    required this.items,
    this.source = '',
    this.engines = const [],
  }) {
    final ids = engines.map((e) => e.id).toList();
    if (ids.toSet().length != ids.length) throw ArgumentError('$id: двигатель указан дважды');
    for (final item in items) {
      for (final eid in item.byEngine.keys) {
        if (!ids.contains(eid)) throw ArgumentError("$id: неизвестный двигатель '$eid' у ${item.consumable.id}");
      }
    }
  }

  bool get fullySourced => items.every((i) => i.sourced);

  /// Пункты с учётом двигателя; null — «не знаю», берутся интервалы по умолчанию.
  List<RegulationItem> itemsFor(String? engineId) {
    if (engineId != null && !engines.any((e) => e.id == engineId)) {
      throw ArgumentError("У $make $model нет двигателя '$engineId'");
    }
    return [for (final i in items) i.forEngine(engineId)];
  }

  bool matches(String make, String model, int year) {
    if (this.make.toLowerCase() != make.toLowerCase() || this.model.toLowerCase() != model.toLowerCase()) {
      return false;
    }
    if (yearFrom != null && year < yearFrom!) return false;
    if (yearTo != null && year > yearTo!) return false;
    return true;
  }
}

// ---------- Данные пользователя ----------

class OdometerReading {
  final DateTime on;
  final int km;
  const OdometerReading(this.on, this.km);

  Map<String, dynamic> toJson() => {'on': isoDate(on), 'km': km};
  factory OdometerReading.fromJson(Map<String, dynamic> j) =>
      OdometerReading(parseIsoDate(j['on'] as String), j['km'] as int);
}

class ServiceRecord {
  final DateTime on;
  final int odometerKm;
  final Set<Consumable> consumables;
  final bool isBaseline; // «последнее ТО», введённое при добавлении авто
  final int? costRub;
  final String comment;
  final List<String> receiptPhotos; // пути к фото чеков
  final TireSeason? tiresMounted; // какой комплект поставили при смене шин

  ServiceRecord({
    required this.on,
    required this.odometerKm,
    required this.consumables,
    this.isBaseline = false,
    this.costRub,
    this.comment = '',
    this.receiptPhotos = const [],
    this.tiresMounted,
  }) {
    if (tiresMounted != null && !consumables.contains(Consumable.tires)) {
      throw ArgumentError('Смена шин должна быть отмечена расходником «Шины»');
    }
  }

  Map<String, dynamic> toJson() => {
        'on': isoDate(on),
        'odometer_km': odometerKm,
        'consumables': [for (final c in consumables) c.id],
        'is_baseline': isBaseline,
        'cost_rub': costRub,
        'comment': comment,
        'receipt_photos': receiptPhotos,
        'tires_mounted': tiresMounted?.id,
      };

  factory ServiceRecord.fromJson(Map<String, dynamic> j) => ServiceRecord(
        on: parseIsoDate(j['on'] as String),
        odometerKm: j['odometer_km'] as int,
        consumables: {for (final c in j['consumables'] as List) Consumable.fromId(c as String)},
        isBaseline: j['is_baseline'] as bool? ?? false,
        costRub: j['cost_rub'] as int?,
        comment: j['comment'] as String? ?? '',
        receiptPhotos: [for (final p in j['receipt_photos'] as List? ?? const []) p as String],
        tiresMounted: j['tires_mounted'] == null ? null : TireSeason.fromId(j['tires_mounted'] as String),
      );
}

class Car {
  final String id;
  String make;
  String model;
  int year;
  String regulationId;
  String? engineId; // null — не знает или у модели нет вариантов
  String? vin;
  int? kmPerMonthDeclared; // «сколько км в месяц вы проезжаете?»
  final List<OdometerReading> readings;
  final List<ServiceRecord> services;
  TireSetup? tireSetup; // null — не спрашивали, о шинах не напоминаем
  bool winterStudded;
  String climateZone; // id из CLIMATE_ZONES (tires.dart)
  (double, double)? location; // (широта, долгота) для прогноза погоды
  String? city;

  Car({
    required this.id,
    required this.make,
    required this.model,
    required this.year,
    required this.regulationId,
    this.engineId,
    this.vin,
    this.kmPerMonthDeclared,
    List<OdometerReading>? readings,
    List<ServiceRecord>? services,
    this.tireSetup,
    this.winterStudded = false,
    this.climateZone = 'center',
    this.location,
    this.city,
  })  : readings = readings ?? [],
        services = services ?? [];

  void addReading(OdometerReading r) {
    _checkMonotonic(r.on, r.km);
    readings.add(r);
  }

  void addService(ServiceRecord r) {
    _checkMonotonic(r.on, r.odometerKm);
    services.add(r);
  }

  /// Все точки «дата — пробег», включая пробег из записей ТО, по возрастанию.
  List<OdometerReading> observations() {
    final points = [...readings, for (final s in services) OdometerReading(s.on, s.odometerKm)];
    points.sort((a, b) {
      final byDate = a.on.compareTo(b.on);
      return byDate != 0 ? byDate : a.km.compareTo(b.km);
    });
    return points;
  }

  /// Текущий известный пробег (последнее показание) или null.
  int? get lastKnownKm {
    final obs = observations();
    return obs.isEmpty ? null : obs.last.km;
  }

  void _checkMonotonic(DateTime on, int km) {
    if (km < 0) throw ArgumentError('Пробег не может быть отрицательным');
    for (final p in observations()) {
      if (p.on.isBefore(on) && p.km > km) {
        throw ArgumentError('Пробег $km км на ${isoDate(on)} меньше, чем ${p.km} км на ${isoDate(p.on)}');
      }
      if (p.on.isAfter(on) && p.km < km) {
        throw ArgumentError('Пробег $km км на ${isoDate(on)} больше, чем ${p.km} км на более позднюю дату ${isoDate(p.on)}');
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'make': make,
        'model': model,
        'year': year,
        'regulation_id': regulationId,
        'engine_id': engineId,
        'vin': vin,
        'km_per_month_declared': kmPerMonthDeclared,
        'readings': [for (final r in readings) r.toJson()],
        'services': [for (final s in services) s.toJson()],
        'tire_setup': tireSetup?.id,
        'winter_studded': winterStudded,
        'climate_zone': climateZone,
        'location': location == null ? null : [location!.$1, location!.$2],
        'city': city,
      };

  factory Car.fromJson(Map<String, dynamic> j) {
    final loc = j['location'] as List?;
    return Car(
      id: j['id'] as String,
      make: j['make'] as String,
      model: j['model'] as String,
      year: j['year'] as int,
      regulationId: j['regulation_id'] as String,
      engineId: j['engine_id'] as String?,
      vin: j['vin'] as String?,
      kmPerMonthDeclared: j['km_per_month_declared'] as int?,
      readings: [for (final r in j['readings'] as List) OdometerReading.fromJson(r as Map<String, dynamic>)],
      services: [for (final s in j['services'] as List) ServiceRecord.fromJson(s as Map<String, dynamic>)],
      tireSetup: j['tire_setup'] == null ? null : TireSetup.fromId(j['tire_setup'] as String),
      winterStudded: j['winter_studded'] as bool? ?? false,
      climateZone: j['climate_zone'] as String? ?? 'center',
      location: loc == null ? null : ((loc[0] as num).toDouble(), (loc[1] as num).toDouble()),
      city: j['city'] as String?,
    );
  }
}

// ---------- Результат расчёта графика ----------

enum Status {
  overdue('Просрочено'),
  soon('Скоро'),
  ok('В норме'),
  unknown('Нет данных'); // нет данных о последней замене — спросить пользователя

  const Status(this.title);
  final String title;
}

enum Trigger {
  km('по пробегу'),
  time('по времени'),
  weather('по прогнозу погоды');

  const Trigger(this.title);
  final String title;
}

class ScheduleItem {
  final Consumable consumable;
  final ServiceAction action;
  final Status status;
  final ServiceRecord? lastService;
  final int? dueKm;
  final DateTime? dueDate; // итоговая дата (раньшая из двух)
  final DateTime? dueByTime;
  final DateTime? dueByKmEstimated;
  final Trigger? trigger;
  final int? remainingKm;
  final int? remainingDays;
  final List<DateTime> reminders;
  // только для сезонной смены шин:
  final TireSeason? tiresToMount;
  final DateTime? windowStart;
  final DateTime? legalDeadline;

  const ScheduleItem({
    required this.consumable,
    required this.action,
    required this.status,
    this.lastService,
    this.dueKm,
    this.dueDate,
    this.dueByTime,
    this.dueByKmEstimated,
    this.trigger,
    this.remainingKm,
    this.remainingDays,
    this.reminders = const [],
    this.tiresToMount,
    this.windowStart,
    this.legalDeadline,
  });
}
