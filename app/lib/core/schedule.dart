// Расчёт графика ТО — перенос avtozabota/core/schedule.py.
//
// Срок наступает по пробегу ИЛИ по времени — что раньше. Чтобы напомнить «за 7 дней»
// о сроке по пробегу, пробег переводится в дату через средний пробег в день.
import 'models.dart';
import 'tires.dart';
import 'weather.dart' show DailyTemp;

const double defaultKmPerDay = 41.0; // ≈ 15 000 км в год, если о водителе ничего не известно
const double daysPerMonth = 30.44;
const rateWindowDays = 365; // средний пробег считаем по последнему году
const minRateSpanDays = 14; // меньше двух недель данных — слишком шумно
const soonDays = 7;
const soonKm = 500;
const remindBeforeDays = [7, 1];

enum RateSource { readings, declared, defaultRate }

/// 31 января + 1 месяц = 28/29 февраля.
DateTime addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day; // 0-й день следующего месяца = последний этого
  return day(year, month, d.day < lastDay ? d.day : lastDay);
}

List<OdometerReading> _knownPoints(Car car, DateTime today) =>
    [for (final p in car.observations()) if (!p.on.isAfter(today)) p];

(double, RateSource) estimateKmPerDay(Car car, DateTime today) {
  final points = _knownPoints(car, today);
  if (points.isNotEmpty) {
    final latest = points.last;
    final window = [for (final p in points) if (daysBetween(p.on, latest.on) <= rateWindowDays) p];
    final first = window.first;
    final span = daysBetween(first.on, latest.on);
    if (span >= minRateSpanDays) {
      final rate = (latest.km - first.km) / span;
      return (rate < 0 ? 0.0 : rate, RateSource.readings);
    }
  }
  if (car.kmPerMonthDeclared != null) return (car.kmPerMonthDeclared! / daysPerMonth, RateSource.declared);
  return (defaultKmPerDay, RateSource.defaultRate);
}

int? estimateOdometer(Car car, DateTime on, double kmPerDay) {
  final points = _knownPoints(car, on);
  if (points.isEmpty) return null;
  final latest = points.last;
  return (latest.km + kmPerDay * daysBetween(latest.on, on)).round();
}

ServiceRecord? lastService(Car car, Consumable consumable, DateTime today) {
  final done = [for (final s in car.services) if (s.consumables.contains(consumable) && !s.on.isAfter(today)) s];
  if (done.isEmpty) return null;
  // Самая поздняя по дате, затем по пробегу; при полном равенстве — добавленная позже.
  return done.reduce((a, b) {
    final c = a.on.compareTo(b.on);
    return (c > 0 || (c == 0 && a.odometerKm > b.odometerKm)) ? a : b;
  });
}

ScheduleItem scheduleItem(Car car, RegulationItem item, DateTime today, double kmPerDay) {
  final last = lastService(car, item.consumable, today);
  if (last == null) {
    return ScheduleItem(consumable: item.consumable, action: item.action, status: Status.unknown);
  }

  final latest = _knownPoints(car, today).last;
  final currentKm = estimateOdometer(car, today, kmPerDay)!;

  int? dueKm;
  int? remainingKm;
  DateTime? dueByKm;
  if (item.intervalKm != null) {
    dueKm = last.odometerKm + item.intervalKm!;
    remainingKm = dueKm - currentKm;
    if (kmPerDay > 0) {
      dueByKm = addDays(latest.on, ((dueKm - latest.km) / kmPerDay).ceil());
    } else if (dueKm <= latest.km) {
      dueByKm = latest.on;
    }
    // машина стоит (0 км/день) и до срока по пробегу далеко — даты по пробегу нет
  }

  final dueByTime = item.intervalMonths != null ? addMonths(last.on, item.intervalMonths!) : null;

  DateTime? dueDate;
  Trigger? trigger;
  for (final (d, t) in [(dueByKm, Trigger.km), (dueByTime, Trigger.time)]) {
    if (d != null && (dueDate == null || d.isBefore(dueDate))) {
      dueDate = d;
      trigger = t;
    }
  }
  if (dueDate == null && dueKm != null) trigger = Trigger.km;
  final remainingDays = dueDate == null ? null : daysBetween(today, dueDate);

  final overdue = (remainingKm != null && remainingKm <= 0) || (remainingDays != null && remainingDays < 0);
  final soon = (remainingKm != null && remainingKm <= soonKm) || (remainingDays != null && remainingDays <= soonDays);
  final status = overdue ? Status.overdue : (soon ? Status.soon : Status.ok);

  final reminders = <DateTime>[];
  if (dueDate != null && !overdue) {
    reminders.addAll({
      for (final n in remindBeforeDays)
        if (!addDays(dueDate, -n).isBefore(today)) addDays(dueDate, -n),
    });
    reminders.sort();
  }

  return ScheduleItem(
    consumable: item.consumable,
    action: item.action,
    status: status,
    lastService: last,
    dueKm: dueKm,
    dueDate: dueDate,
    dueByTime: dueByTime,
    dueByKmEstimated: dueByKm,
    trigger: trigger,
    remainingKm: remainingKm,
    remainingDays: remainingDays,
    reminders: reminders,
  );
}

const _statusOrder = {Status.overdue: 0, Status.soon: 1, Status.unknown: 2, Status.ok: 3};

/// График по всем расходникам: сначала просроченные, затем ближайшие.
/// [forecast] — температура по дням для города машины; без него шины считаются по календарю.
List<ScheduleItem> buildSchedule(Car car, Regulation regulation, DateTime today, {List<DailyTemp>? forecast}) {
  if (regulation.id != car.regulationId) throw ArgumentError('Регламент не соответствует автомобилю');
  final (kmPerDay, _) = estimateKmPerDay(car, today);
  final items = [for (final it in regulation.itemsFor(car.engineId)) scheduleItem(car, it, today, kmPerDay)];
  final tires = tireItem(car, today, forecast: forecast);
  if (tires != null) items.add(tires);
  final far = day(9999, 12, 31);
  items.sort((a, b) {
    final s = _statusOrder[a.status]!.compareTo(_statusOrder[b.status]!);
    return s != 0 ? s : (a.dueDate ?? far).compareTo(b.dueDate ?? far);
  });
  return items;
}
