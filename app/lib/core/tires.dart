// Сезонная смена шин — перенос avtozabota/core/tires.py.
//
// По умолчанию — календарные окна климатической зоны; если есть свежий прогноз
// погоды — срок по погоде. Закон (ТР ТС 018/2011, прил. 8, п. 5.5): зимние шины
// обязательны в декабре–феврале, шипованные запрещены в июне–августе.
import 'models.dart';
import 'weather.dart' as weather;
import 'weather.dart' show DailyTemp;

typedef MonthDay = (int month, int day);

const MonthDay winterTiresRequiredFrom = (12, 1);
const MonthDay studsForbiddenFrom = (6, 1);
const remindBeforeWindowDays = 7;
const remindBeforeLegalDays = 7;
const weatherWindowDays = 7; // сколько дней после начала похолодания/потепления даём на смену
const weatherHeadsUpDays = 3; // предупреждение заранее, если смена по прогнозу ещё впереди

class ClimateZone {
  final String id;
  final String title;
  final (MonthDay, MonthDay) spring; // окно смены на летние
  final (MonthDay, MonthDay) autumn; // окно смены на зимние
  const ClimateZone(this.id, this.title, {required this.spring, required this.autumn});
}

/// Ориентиры из рекомендаций Минтранса и автоизданий; см. README → «Сезонная смена шин».
const climateZones = <String, ClimateZone>{
  'south': ClimateZone('south', 'Юг (Крым, Краснодарский край, Ростов, Ставрополь)',
      spring: ((3, 15), (4, 10)), autumn: ((11, 1), (11, 30))),
  'center': ClimateZone('center', 'Центр, Северо-Запад, Поволжье',
      spring: ((4, 1), (4, 25)), autumn: ((10, 15), (10, 31))),
  'north_east': ClimateZone('north_east', 'Урал, Сибирь, Север, Дальний Восток',
      spring: ((4, 25), (5, 15)), autumn: ((9, 20), (10, 15))),
};

(DateTime, DateTime) _window((MonthDay, MonthDay) w, int year) =>
    (day(year, w.$1.$1, w.$1.$2), day(year, w.$2.$1, w.$2.$2));

/// Год окна, в которое этот комплект надо снять. Летние, поставленные в январе, относятся
/// к прошлой зиме; зимние, поставленные с августа, снимаются весной следующего года.
int _swapYear(TireSeason mounted, DateTime on) {
  if (mounted == TireSeason.summer) return on.month == 1 ? on.year - 1 : on.year;
  return on.month >= 8 ? on.year + 1 : on.year;
}

/// Езда на текущем комплекте сегодня нарушает ТР ТС.
bool _illegalNow(TireSeason target, bool studded, DateTime today) {
  if (target == TireSeason.winter) return const {12, 1, 2}.contains(today.month); // стоят летние
  return studded && const {6, 7, 8}.contains(today.month); // стоят зимние с шипами
}

ServiceRecord? lastTireSwap(Car car, DateTime today) {
  final swaps = [for (final s in car.services) if (s.tiresMounted != null && !s.on.isAfter(today)) s];
  if (swaps.isEmpty) return null;
  // При одинаковой дате побеждает запись, добавленная позже (например, стартовая «стоят летние»
  // и смена на зимние в тот же день).
  return swaps.reduce((a, b) => b.on.isBefore(a.on) ? a : b);
}

List<DateTime> _sortedFrom(Iterable<DateTime> dates, DateTime today) =>
    ({for (final d in dates) if (!d.isBefore(today)) d}.toList()..sort());

/// Пункт графика «сменить шины» или null, если напоминать не о чем.
ScheduleItem? tireItem(Car car, DateTime today, {List<DailyTemp>? forecast}) {
  if (car.tireSetup == null || car.tireSetup == TireSetup.allSeason) return null;
  final zone = climateZones[car.climateZone];
  if (zone == null) throw ArgumentError('Неизвестная климатическая зона: ${car.climateZone}');

  final last = lastTireSwap(car, today);
  if (last == null) {
    // не знаем, какие шины стоят, — интерфейс спросит
    return const ScheduleItem(consumable: Consumable.tires, action: ServiceAction.seasonalSwap, status: Status.unknown);
  }

  final mounted = last.tiresMounted!;
  final target = mounted == TireSeason.summer ? TireSeason.winter : TireSeason.summer;
  final (start, end) = _window(target == TireSeason.winter ? zone.autumn : zone.spring, _swapYear(mounted, last.on));

  DateTime? legal;
  if (target == TireSeason.winter) {
    legal = day(end.year, winterTiresRequiredFrom.$1, winterTiresRequiredFrom.$2);
  } else if (car.winterStudded) {
    legal = day(end.year, studsForbiddenFrom.$1, studsForbiddenFrom.$2);
  }
  final illegal = _illegalNow(target, car.winterStudded, today);
  final legalReminder = [if (legal != null) addDays(legal, -remindBeforeLegalDays)];

  if (forecast != null && forecast.isNotEmpty && weather.covers(forecast, today)) {
    return _byWeather(last, target, legal, illegal, legalReminder, forecast, today);
  }

  final Status status;
  if (today.isAfter(end) || illegal) {
    status = Status.overdue;
  } else if (!today.isBefore(addDays(start, -remindBeforeWindowDays))) {
    status = Status.soon;
  } else {
    status = Status.ok;
  }

  return ScheduleItem(
    consumable: Consumable.tires,
    action: ServiceAction.seasonalSwap,
    status: status,
    lastService: last,
    dueDate: end,
    dueByTime: end,
    trigger: Trigger.time,
    remainingDays: daysBetween(today, end),
    reminders: _sortedFrom([addDays(start, -remindBeforeWindowDays), start, ...legalReminder], today),
    tiresToMount: target,
    windowStart: start,
    legalDeadline: legal,
  );
}

ScheduleItem _byWeather(ServiceRecord last, TireSeason target, DateTime? legal, bool illegal,
    List<DateTime> legalReminder, List<DailyTemp> forecast, DateTime today) {
  final signal = weather.swapSignal(forecast, target, notBefore: last.on);
  final legalSoon = legal != null && !today.isBefore(addDays(legal, -remindBeforeLegalDays));

  if (signal == null) {
    // по прогнозу ещё рано — напоминаем только о законе
    return ScheduleItem(
      consumable: Consumable.tires,
      action: ServiceAction.seasonalSwap,
      status: illegal ? Status.overdue : (legalSoon ? Status.soon : Status.ok),
      lastService: last,
      trigger: Trigger.weather,
      reminders: _sortedFrom(legalReminder, today),
      tiresToMount: target,
      legalDeadline: legal,
    );
  }

  final end = addDays(signal, weatherWindowDays);
  final Status status;
  if (today.isAfter(end) || illegal) {
    status = Status.overdue;
  } else if (!today.isBefore(addDays(signal, -remindBeforeWindowDays)) || legalSoon) {
    status = Status.soon;
  } else {
    status = Status.ok;
  }
  final todayOrSignal = signal.isAfter(today) ? signal : today;
  return ScheduleItem(
    consumable: Consumable.tires,
    action: ServiceAction.seasonalSwap,
    status: status,
    lastService: last,
    dueDate: end,
    dueByTime: end,
    trigger: Trigger.weather,
    remainingDays: daysBetween(today, end),
    reminders: _sortedFrom([addDays(signal, -weatherHeadsUpDays), signal, todayOrSignal, ...legalReminder], today),
    tiresToMount: target,
    windowStart: signal,
    legalDeadline: legal,
  );
}
