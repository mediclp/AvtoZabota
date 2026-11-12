// Тесты логики — те же случаи и цифры, что в avtozabota/tests/test_schedule.py.
import 'dart:io';

import 'package:avtozabota/core/cities.dart';
import 'package:avtozabota/core/format.dart';
import 'package:avtozabota/core/models.dart';
import 'package:avtozabota/core/notification_plan.dart';
import 'package:avtozabota/core/regulations.dart';
import 'package:avtozabota/core/schedule.dart';
import 'package:avtozabota/core/tires.dart';
import 'package:avtozabota/core/weather.dart';
import 'package:flutter_test/flutter_test.dart';

const oil = Consumable.engineOil;
final oilItem = RegulationItem(consumable: oil, action: ServiceAction.replace, intervalKm: 15000, intervalMonths: 12);
final today = day(2026, 11, 12);

Car makeCar(DateTime baselineOn, int baselineKm,
    {List<(DateTime, int)> readings = const [], int? declared, Set<Consumable> consumables = const {oil}}) {
  final car = Car(id: 'c1', make: 'Lada', model: 'Vesta', year: 2020, regulationId: 'test', kmPerMonthDeclared: declared);
  car.addService(ServiceRecord(on: baselineOn, odometerKm: baselineKm, consumables: consumables, isBaseline: true));
  for (final (on, km) in readings) {
    car.addReading(OdometerReading(on, km));
  }
  return car;
}

ScheduleItem oilSchedule(Car car) => scheduleItem(car, oilItem, today, estimateKmPerDay(car, today).$1);

Map<String, Regulation> loadRegs() => parseRegulations(File('assets/data/regulations.json').readAsStringSync());
List<City> loadCities() => parseCities(File('assets/data/cities.json').readAsStringSync());

List<DailyTemp> temps(DateTime start, List<num> means, [List<num>? mins]) => [
      for (var i = 0; i < means.length; i++)
        DailyTemp(addDays(start, i), means[i].toDouble(), (mins?[i] ?? means[i] - 3).toDouble()),
    ];

Car tireCar(DateTime mountedOn, TireSeason season,
    {String zone = 'center', bool studded = false, TireSetup setup = TireSetup.seasonal}) {
  final car = makeCar(day(2025, 1, 1), 1000)
    ..tireSetup = setup
    ..climateZone = zone
    ..winterStudded = studded;
  final km = 1000 + daysBetween(day(2025, 1, 1), mountedOn) * 30;
  car.addService(ServiceRecord(on: mountedOn, odometerKm: km, consumables: {Consumable.tires}, tiresMounted: season));
  return car;
}

void main() {
  group('addMonths', () {
    test('конец месяца', () {
      expect(addMonths(day(2026, 1, 31), 1), day(2026, 2, 28));
      expect(addMonths(day(2024, 1, 31), 1), day(2024, 2, 29));
    });
    test('через годы', () => expect(addMonths(day(2026, 11, 15), 14), day(2028, 1, 15)));
  });

  group('средний пробег', () {
    test('по умолчанию', () {
      expect(estimateKmPerDay(makeCar(day(2026, 11, 1), 1000), today), (defaultKmPerDay, RateSource.defaultRate));
    });
    test('со слов пользователя', () {
      final (rate, src) = estimateKmPerDay(makeCar(day(2026, 11, 1), 1000, declared: 1522), today);
      expect(src, RateSource.declared);
      expect(rate, closeTo(50.0, 0.1));
    });
    test('по показаниям важнее слов', () {
      final car = makeCar(day(2026, 10, 1), 1000, readings: [(day(2026, 10, 31), 1900)], declared: 5000);
      expect(estimateKmPerDay(car, today), (30.0, RateSource.readings));
    });
    test('короткий период не считается', () {
      final car = makeCar(day(2026, 11, 1), 1000, readings: [(day(2026, 11, 10), 2000)]);
      expect(estimateKmPerDay(car, today).$2, RateSource.defaultRate);
    });
  });

  group('пункт графика', () {
    test('мало ездит — срок по времени', () {
      final s = oilSchedule(makeCar(day(2026, 1, 10), 50000, readings: [(day(2026, 11, 1), 55000)]));
      expect(s.trigger, Trigger.time);
      expect(s.dueDate, day(2027, 1, 10));
      expect(s.dueKm, 65000);
      expect(s.status, Status.ok);
      expect(s.reminders, [day(2027, 1, 3), day(2027, 1, 9)]);
    });
    test('много ездит — срок по пробегу', () {
      final s = oilSchedule(makeCar(day(2026, 6, 1), 100000, readings: [(day(2026, 11, 1), 112000)]));
      expect(s.trigger, Trigger.km);
      expect(s.dueDate, day(2026, 12, 10));
      expect(s.remainingKm, 2137);
      expect(s.remainingDays, 28);
      expect(s.status, Status.ok);
    });
    test('пробег превышен — просрочено, даже если дата не прошла', () {
      final s = oilSchedule(makeCar(day(2026, 6, 1), 100000, readings: [(day(2026, 11, 10), 116000)]));
      expect(s.status, Status.overdue);
      expect(s.remainingKm! < 0, isTrue);
      expect(s.reminders, isEmpty);
    });
    test('скоро, прошедшие напоминания отброшены', () {
      final s = oilSchedule(makeCar(day(2025, 11, 15), 10000, declared: 300));
      expect(s.dueDate, day(2026, 11, 15));
      expect(s.status, Status.soon);
      expect(s.reminders, [day(2026, 11, 14)]);
    });
    test('новая запись ТО сбрасывает срок', () {
      final car = makeCar(day(2026, 6, 1), 100000, readings: [(day(2026, 11, 10), 116000)]);
      car.addService(ServiceRecord(on: day(2026, 11, 11), odometerKm: 116100, consumables: {oil}, costRub: 4500));
      final s = oilSchedule(car);
      expect(s.dueKm, 131100);
      expect(s.status, Status.ok);
    });
    test('две записи в один день с тем же пробегом — берётся добавленная позже', () {
      final car = makeCar(today, 50000);
      car.addService(ServiceRecord(on: today, odometerKm: 50000, consumables: {oil}, costRub: 4500));
      expect(lastService(car, oil, today)!.costRub, 4500);
    });
    test('машина стоит — только по времени', () {
      final s = oilSchedule(makeCar(day(2026, 1, 1), 20000, readings: [(day(2026, 11, 1), 20000)]));
      expect(s.dueByKmEstimated, isNull);
      expect(s.trigger, Trigger.time);
      expect(s.dueDate, day(2027, 1, 1));
    });
    test('нет записи о замене — нет данных', () {
      expect(oilSchedule(makeCar(day(2026, 1, 1), 20000, consumables: {Consumable.airFilter})).status, Status.unknown);
    });
  });

  group('весь график', () {
    test('просроченные первыми', () {
      final reg = Regulation(id: 'test', make: 'Lada', model: 'Vesta', items: [
        RegulationItem(consumable: Consumable.sparkPlugs, action: ServiceAction.replace, intervalKm: 30000),
        oilItem,
      ]);
      final car = makeCar(day(2026, 6, 1), 100000,
          readings: [(day(2026, 11, 10), 116000)], consumables: {oil, Consumable.sparkPlugs});
      final result = buildSchedule(car, reg, today);
      expect([for (final s in result) s.consumable], [oil, Consumable.sparkPlugs]);
      expect(result.first.status, Status.overdue);
    });
    test('чужой регламент', () {
      final reg = Regulation(id: 'other', make: 'Kia', model: 'Rio', items: [oilItem]);
      expect(() => buildSchedule(makeCar(day(2026, 1, 1), 1000), reg, today), throwsArgumentError);
    });
  });

  group('проверки ввода', () {
    test('пробег не уменьшается', () {
      final car = makeCar(day(2026, 6, 1), 100000);
      expect(() => car.addReading(OdometerReading(day(2026, 7, 1), 99000)), throwsArgumentError);
    });
    test('два показания в один день можно', () {
      makeCar(day(2026, 6, 1), 100000).addReading(OdometerReading(day(2026, 6, 1), 100050));
    });
    test('пункт без интервала', () {
      expect(() => RegulationItem(consumable: oil, action: ServiceAction.replace), throwsArgumentError);
    });
    test('машина сохраняется и читается из JSON без потерь', () {
      final car = tireCar(day(2026, 4, 20), TireSeason.summer)
        ..engineId = '2.0_mpi'
        ..location = (44.61, 33.52)
        ..city = 'Севастополь';
      final back = Car.fromJson(car.toJson());
      expect(back.toJson(), car.toJson());
    });
  });

  group('справочник регламентов', () {
    final regs = loadRegs();
    test('у каждой модели масло, интервал из источника и правдоподобный', () {
      for (final r in regs.values) {
        if (r.id == genericId) continue;
        final o = r.items.firstWhere((i) => i.consumable == oil);
        expect(o.sourced, isTrue, reason: r.id);
        expect(o.intervalKm, inInclusiveRange(5000, 20000), reason: r.id);
        expect(o.intervalMonths, inInclusiveRange(6, 24), reason: r.id);
      }
    });
    test('все расходники кроме шин и источник', () {
      final full = Consumable.values.where((c) => c != Consumable.tires).toSet();
      for (final r in regs.values) {
        expect(r.items.map((i) => i.consumable).toSet(), full, reason: r.id);
        expect(r.source, isNotEmpty, reason: r.id);
      }
    });
    test('поиск модели без учёта регистра и запасной общий', () {
      expect(findRegulation(regs, 'KIA', 'rio', 2019).id, 'kia_rio');
      expect(findRegulation(regs, 'Chery', 'Tiggo 7 Pro Max', 2024).id, 'chery_tiggo_7_pro_max');
      expect(findRegulation(regs, 'Moskvich', '3', 2023).id, genericId);
      expect(findRegulation(regs, 'Kia', 'Rio', 2008).id, genericId);
    });
    test('каталог для выпадающих списков', () {
      final cat = catalog(regs);
      expect(cat['Lada'], contains('Granta'));
      expect(cat.containsKey('*'), isFalse);
    });
  });

  group('двигатели', () {
    final sportage = loadRegs()['kia_sportage']!;
    RegulationItem plugs(String? e) => sportage.itemsFor(e).firstWhere((i) => i.consumable == Consumable.sparkPlugs);
    test('двигатель не указан — самый частый интервал', () => expect(plugs(null).intervalKm, 40000));
    test('вариант двигателя меняет только свои пункты', () {
      expect(plugs('2.0_mpi').intervalKm, 150000);
      expect(plugs('2.0_mpi').intervalMonths, isNull);
      expect(sportage.itemsFor('2.0_mpi').firstWhere((i) => i.consumable == oil).intervalKm, 10000);
    });
    test('неизвестный двигатель', () => expect(() => sportage.itemsFor('1.5_tsi'), throwsArgumentError));
    test('график учитывает двигатель машины', () {
      final car = Car(id: 's', make: 'Kia', model: 'Sportage', year: 2019, regulationId: 'kia_sportage', engineId: '2.0_mpi');
      car.addService(ServiceRecord(on: day(2026, 1, 1), odometerKm: 30000, consumables: Consumable.values.toSet(), isBaseline: true));
      int? plugsDue() => buildSchedule(car, sportage, today).firstWhere((s) => s.consumable == Consumable.sparkPlugs).dueKm;
      expect(plugsDue(), 180000);
      car.engineId = null;
      expect(plugsDue(), 70000);
    });
  });

  group('шины по календарю', () {
    test('летние → зимние, всё в порядке', () {
      final s = tireItem(tireCar(day(2026, 4, 20), TireSeason.summer), day(2026, 9, 1))!;
      expect(s.status, Status.ok);
      expect(s.tiresToMount, TireSeason.winter);
      expect((s.windowStart, s.dueDate), (day(2026, 10, 15), day(2026, 10, 31)));
      expect(s.legalDeadline, day(2026, 12, 1));
      expect(s.reminders, [day(2026, 10, 8), day(2026, 10, 15), day(2026, 11, 24)]);
    });
    test('скоро — за неделю до окна', () {
      expect(tireItem(tireCar(day(2026, 4, 20), TireSeason.summer), day(2026, 10, 10))!.status, Status.soon);
    });
    test('просрочено, но напоминание о законе остаётся', () {
      final s = tireItem(tireCar(day(2026, 4, 20), TireSeason.summer), today)!;
      expect(s.status, Status.overdue);
      expect(s.reminders, [day(2026, 11, 24)]);
    });
    test('добавили машину в ноябре с летними — менять сейчас, а не через год', () {
      final s = tireItem(tireCar(today, TireSeason.summer), today)!;
      expect(s.status, Status.overdue);
      expect(s.dueDate, day(2026, 10, 31));
    });
    test('зимние → летние следующей весной', () {
      final s = tireItem(tireCar(day(2026, 10, 20), TireSeason.winter), today)!;
      expect(s.status, Status.ok);
      expect(s.windowStart, day(2027, 4, 1));
      expect(s.legalDeadline, isNull);
      expect(s.reminders, [day(2027, 3, 25), day(2027, 4, 1)]);
    });
    test('у шипов есть законный срок', () {
      final s = tireItem(tireCar(day(2026, 10, 1), TireSeason.winter, zone: 'north_east', studded: true), today)!;
      expect(s.windowStart, day(2027, 4, 25));
      expect(s.legalDeadline, day(2027, 6, 1));
      expect(s.reminders, contains(day(2027, 5, 25)));
    });
    test('летние в феврале — нарушение', () {
      expect(tireItem(tireCar(day(2026, 2, 10), TireSeason.summer, zone: 'south'), day(2026, 2, 20))!.status,
          Status.overdue);
    });
    test('зоны сдвигают окна', () {
      expect(tireItem(tireCar(day(2026, 4, 20), TireSeason.summer, zone: 'south'), day(2026, 9, 1))!.windowStart,
          day(2026, 11, 1));
      expect(tireItem(tireCar(day(2026, 4, 20), TireSeason.summer, zone: 'north_east'), day(2026, 9, 1))!.windowStart,
          day(2026, 9, 20));
    });
    test('смена шин в день добавления машины — побеждает более поздняя запись', () {
      // при добавлении: «стоят летние», и в тот же день отметили «поставили зимние»
      final car = tireCar(today, TireSeason.summer);
      car.addService(ServiceRecord(on: today, odometerKm: car.lastKnownKm!, consumables: {Consumable.tires},
          tiresMounted: TireSeason.winter));
      final s = tireItem(car, today)!;
      expect(s.tiresToMount, TireSeason.summer);
      expect(s.status, Status.ok);
    });
    test('напоминать не о чем', () {
      expect(tireItem(tireCar(today, TireSeason.winter, setup: TireSetup.allSeason), today), isNull);
      expect(tireItem(makeCar(day(2026, 1, 1), 1000), today), isNull);
    });
    test('неизвестно, какие стоят', () {
      final car = makeCar(day(2026, 1, 1), 1000)..tireSetup = TireSetup.seasonal;
      expect(tireItem(car, today)!.status, Status.unknown);
    });
    test('ошибки ввода', () {
      expect(() => ServiceRecord(on: today, odometerKm: 1000, consumables: {oil}, tiresMounted: TireSeason.winter),
          throwsArgumentError);
      expect(() => tireItem(tireCar(today, TireSeason.winter, zone: 'mars'), today), throwsArgumentError);
    });
  });

  group('погода', () {
    test('разбор ответа пропускает пустые дни', () {
      final payload = {
        'daily': {
          'time': ['2026-11-05', '2026-11-06'],
          'temperature_2m_mean': [1.8, null],
          'temperature_2m_min': [-0.2, 0.5],
        }
      };
      expect(parseOpenMeteo(payload), [DailyTemp(day(2026, 11, 5), 1.8, -0.2)]);
    });
    test('устойчивый холод', () {
      expect(swapSignal(temps(day(2026, 10, 20), [9, 8, 6, 5, 6, 4, 3]), TireSeason.winter), day(2026, 10, 22));
    });
    test('короткое похолодание не считается', () {
      expect(swapSignal(temps(day(2026, 10, 20), [6, 5, 8, 6, 5, 4, 9]), TireSeason.winter), isNull);
    });
    test('летние — без ночных заморозков', () {
      final t = temps(day(2026, 4, 10), [8, 9, 10, 9, 8, 9, 10, 11, 12, 10], [1, 2, -1, 2, 3, 2, 3, 4, 5, 4]);
      expect(swapSignal(t, TireSeason.summer), day(2026, 4, 13));
    });
    test('аномалии не в сезон', () {
      expect(swapSignal(temps(day(2026, 5, 10), List.filled(7, 4)), TireSeason.winter), isNull);
      expect(swapSignal(temps(day(2027, 1, 10), List.filled(7, 9), List.filled(7, 1)), TireSeason.summer), isNull);
    });
    test('разрыв в данных обрывает серию', () {
      final t = [...temps(day(2026, 10, 20), [5, 5, 5]), ...temps(day(2026, 10, 24), [5, 5, 5])];
      expect(swapSignal(t, TireSeason.winter), isNull);
    });
    test('notBefore', () {
      expect(swapSignal(temps(day(2026, 10, 20), List.filled(10, 5)), TireSeason.winter, notBefore: day(2026, 10, 23)),
          day(2026, 10, 23));
    });
  });

  group('шины по погоде', () {
    Car summerCar() => tireCar(day(2026, 4, 20), TireSeason.summer);
    test('холод раньше календаря', () {
      final s = tireItem(summerCar(), day(2026, 10, 5),
          forecast: temps(day(2026, 9, 28), [...List.filled(11, 12), ...List.filled(12, 5)]))!;
      expect(s.trigger, Trigger.weather);
      expect(s.windowStart, day(2026, 10, 9));
      expect(s.status, Status.soon);
      expect(s.reminders, [day(2026, 10, 6), day(2026, 10, 9), day(2026, 11, 24)]);
    });
    test('тёплая осень — не просрочено до закона', () {
      final car = summerCar();
      List<DailyTemp> warm(DateTime t) => temps(addDays(t, -7), List.filled(23, 10));
      final s = tireItem(car, day(2026, 11, 5), forecast: warm(day(2026, 11, 5)))!;
      // списки в Dart сравниваются по ссылке, поэтому reminders проверяем отдельно (expect сравнит поэлементно)
      expect((s.status, s.dueDate), (Status.ok, null));
      expect(s.reminders, [day(2026, 11, 24)]);
      expect(tireItem(car, day(2026, 11, 26), forecast: warm(day(2026, 11, 26)))!.status, Status.soon);
      expect(tireItem(car, day(2026, 12, 2), forecast: warm(day(2026, 12, 2)))!.status, Status.overdue);
    });
    test('устаревший прогноз — по календарю', () {
      final s = tireItem(summerCar(), day(2026, 10, 5), forecast: temps(day(2026, 9, 1), List.filled(10, 5)))!;
      expect(s.trigger, Trigger.time);
      expect(s.windowStart, day(2026, 10, 15));
    });
  });

  group('форматирование', () {
    test('даты и километры', () {
      expect(fmtDate(day(2026, 3, 5)), '05.03.2026');
      expect(fmtKm(115000), '115 000 км');
      expect(fmtKm(950), '950 км');
      expect(fmtKm(-1200), '−1 200 км');
      expect([fmtDaysLeft(0), fmtDaysLeft(1), fmtDaysLeft(5), fmtDaysLeft(-3)],
          ['сегодня', 'завтра', 'через 5 дн.', '3 дн. назад']);
    });
    test('текст пункта и напоминания', () {
      final car = makeCar(day(2026, 6, 1), 100000, readings: [(day(2026, 11, 1), 112000)]);
      final s = oilSchedule(car);
      expect(itemDetails(s), contains('до 10.12.2026 (через 28 дн., по пробегу)'));
      expect(reminderText(car, s), 'Lada Vesta: Моторное масло и масляный фильтр — до 10.12.2026');
      final t = tireItem(tireCar(day(2026, 4, 20), TireSeason.summer), day(2026, 9, 1))!;
      expect(itemTitle(t), 'Поставить зимние шины');
      expect(itemDetails(t), 'менять 15.10–31.10 · по закону до 01.12.2026');
    });
  });

  group('план уведомлений', () {
    test('напоминания в 10:00 в дни из графика', () {
      final car = makeCar(day(2026, 1, 10), 50000, readings: [(day(2026, 11, 1), 55000)]);
      final plan = planNotifications([(car, [oilSchedule(car)])], DateTime(2026, 11, 12, 12, 0));
      expect([for (final p in plan) p.at], [DateTime(2027, 1, 3, 10), DateTime(2027, 1, 9, 10)]);
      expect([for (final p in plan) p.id], [1, 2]);
      expect(plan.first.title, 'Скоро замена на ТО');
      expect(plan.first.body, 'Lada Vesta: Моторное масло и масляный фильтр — до 10.01.2027 (через 7 дн.)');
    });
    test('сегодняшнее напоминание после 10:00 — через минуту, но только один раз и не ночью', () {
      final car = makeCar(day(2025, 11, 13), 10000, declared: 300); // масло до 13.11.2026 → напомнить 12.11
      final items = [oilSchedule(car)];
      expect(items.single.reminders, [today]);
      final afternoon = DateTime(2026, 11, 12, 15, 0);
      final plan = planNotifications([(car, items)], afternoon);
      expect(plan.single.at, afternoon.add(lateTodayDelay));
      expect(plan.single.lateToday, isTrue);
      final late = {plan.single.key: plan.single.at};
      // через 30 секунд данные изменились, план пересобран — время то же, а не «ещё через минуту»
      final again = planNotifications([(car, items)], afternoon.add(const Duration(seconds: 30)), lateToday: late);
      expect(again.single.at, plan.single.at);
      // через 5 минут уже показали — больше не ставим
      expect(planNotifications([(car, items)], afternoon.add(const Duration(minutes: 5)), lateToday: late), isEmpty);
      expect(planNotifications([(car, items)], DateTime(2026, 11, 12, 22, 0)), isEmpty);
      expect(planNotifications([(car, items)], DateTime(2026, 11, 12, 8, 0)).single.at, DateTime(2026, 11, 12, 10));
    });
    test('своё время уведомлений и ограничение количества', () {
      final car = makeCar(day(2026, 1, 1), 1000);
      final item = ScheduleItem(
          consumable: oil,
          action: ServiceAction.replace,
          status: Status.ok,
          reminders: [for (var i = 60; i >= 1; i--) addDays(today, i)]);
      final plan = planNotifications([(car, [item])], DateTime(2026, 11, 12, 12), hour: 19, minute: 30);
      expect(plan.length, maxPlannedNotifications);
      expect(plan.first.at, DateTime(2026, 11, 13, 19, 30)); // ближайшие первыми
      expect(plan.map((p) => p.id).toSet().length, plan.length);
    });
  });

  group('города', () {
    final cities = loadCities();
    final byName = {for (final c in cities) c.name: c};
    test('зона по координатам', () {
      const expected = {
        'Севастополь': 'south', 'Сочи': 'south', 'Ростов-на-Дону': 'south',
        'Москва': 'center', 'Калининград': 'center', 'Казань': 'center',
        'Екатеринбург': 'north_east', 'Новосибирск': 'north_east', 'Мурманск': 'north_east',
        'Петрозаводск': 'north_east', 'Владивосток': 'north_east',
      };
      expected.forEach((name, zone) => expect(byName[name]!.climateZone, zone, reason: name));
    });
    test('список корректный', () {
      expect(cities.length, greaterThanOrEqualTo(70));
      expect(byName.length, cities.length);
      for (final c in cities) {
        expect(c.lat >= 41 && c.lat <= 82 && c.lon >= 19 && c.lon <= 180, isTrue, reason: c.name);
        expect(climateZones.containsKey(c.climateZone), isTrue);
        expect(RegExp('[A-Za-z]').hasMatch(c.region), isFalse, reason: c.title);
      }
    });
    test('поиск', () {
      String first(String q) => searchCities(q, cities).first.name;
      expect(first('орел'), 'Орёл');
      expect(first('ростов на'), 'Ростов-на-Дону');
      expect(first('СЕВАСТ'), 'Севастополь');
      expect(first('нов'), 'Новосибирск');
      final names = searchCities('нов', cities, limit: 20).map((c) => c.name).toList();
      expect(names, contains('Великий Новгород'));
      expect(names.indexOf('Новороссийск') < names.indexOf('Великий Новгород'), isTrue);
      expect(searchCities('  ', cities), isEmpty);
    });
    test('геокодер: только населённые пункты, крупные первыми', () {
      final payload = {
        'results': [
          {'name': 'Мурманский', 'latitude': -69.6, 'longitude': 13.3, 'feature_code': 'CAPE'},
          {'name': 'Ступино', 'admin1': 'Архангельская Область', 'latitude': 63.9, 'longitude': 41.7, 'feature_code': 'PPL'},
          {'name': 'Ступино', 'admin1': 'Московская область', 'latitude': 54.9, 'longitude': 38.1, 'population': 60999,
            'feature_code': 'PPLA2'},
          {'name': 'Казан', 'admin1': 'Анкара', 'latitude': 40.2, 'longitude': 32.7, 'population': 50000,
            'feature_code': 'PPLA2'}, // вне рамки зон — отбрасывается
        ]
      };
      expect(parseGeocoding(payload).map((c) => c.region), ['Московская область', 'Архангельская Область']);
    });
    test('привязка машины к городу', () {
      final car = makeCar(day(2026, 1, 1), 1000);
      applyCity(car, byName['Севастополь']!);
      expect(car.city, 'Севастополь');
      expect(car.location, (44.61, 33.52));
      expect(car.climateZone, 'south');
      car.tireSetup = TireSetup.seasonal;
      car.addService(ServiceRecord(on: day(2026, 4, 1), odometerKm: 2000, consumables: {Consumable.tires},
          tiresMounted: TireSeason.summer));
      expect(tireItem(car, day(2026, 9, 1))!.windowStart, day(2026, 11, 1));
    });
  });
}
