// Проверка экранов: приложение запускается, машина добавляется и показывается её график.
import 'package:avtozabota/core/models.dart';
import 'package:avtozabota/data/notifications.dart';
import 'package:avtozabota/data/store.dart';
import 'package:avtozabota/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // нужен для чтения assets в обычных test()

  testWidgets('пустой список → машина → график → сохранение', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final notifier = NoopNotifier();
    final store = (await tester.runAsync(() => AppStore.load(clock: () => DateTime(2026, 11, 12), notifier: notifier)))!;

    await tester.pumpWidget(AvtoZabotaApp(store: store));
    expect(find.text('Добавьте машину'), findsOneWidget);

    final car = Car(id: '1', make: 'Lada', model: 'Vesta', year: 2020, regulationId: 'lada_vesta');
    car.addService(ServiceRecord(
        on: day(2026, 1, 10), odometerKm: 50000, consumables: Consumable.values.toSet()..remove(Consumable.tires),
        isBaseline: true));
    car.addReading(OdometerReading(day(2026, 11, 12), 64800));
    await tester.runAsync(() => store.addCar(car));
    await tester.pumpAndSettle();

    expect(find.text('Lada Vesta, 2020'), findsOneWidget);
    expect(find.text('Скоро'), findsOneWidget); // до 65 000 км осталось 200 км

    await tester.tap(find.text('Lada Vesta, 2020'));
    await tester.pumpAndSettle();
    expect(find.text('Моторное масло и масляный фильтр'), findsOneWidget);
    expect(find.text('Отметить ТО'), findsOneWidget);

    // уведомления выключены по умолчанию — ничего не планируется
    expect(notifier.lastPlan, isEmpty);
    // включили — план строится по графику машины (масло скоро: осталось 200 км)
    await tester.runAsync(() => store.setNotificationsEnabled(true));
    expect(store.notificationsEnabled, isFalse, reason: 'заглушка не даёт разрешения — включение отклонено');

    // данные пережили «перезапуск»: новое хранилище читает то же из SharedPreferences
    final reloaded =
        (await tester.runAsync(() => AppStore.load(clock: () => DateTime(2026, 11, 12), notifier: NoopNotifier())))!;
    expect(reloaded.cars.single.toJson(), car.toJson());
  });

  test('включённые уведомления перепланируются после каждого изменения', () async {
    SharedPreferences.setMockInitialValues({'notify_enabled': true, 'notify_time': '9:30'});
    final notifier = NoopNotifier();
    final store = await AppStore.load(clock: () => DateTime(2026, 11, 12, 8, 0), notifier: notifier);
    final car = Car(id: '1', make: 'Lada', model: 'Vesta', year: 2020, regulationId: 'lada_vesta');
    car.addService(ServiceRecord(
        on: day(2026, 1, 10), odometerKm: 50000, consumables: Consumable.values.toSet()..remove(Consumable.tires),
        isBaseline: true));
    car.addReading(OdometerReading(day(2026, 11, 12), 64800));
    await store.addCar(car);
    expect(notifier.lastPlan, isNotEmpty);
    expect(notifier.lastPlan.every((p) => p.at.hour == 9 && p.at.minute == 30), isTrue);

    await store.setNotificationsEnabled(false);
    expect(notifier.lastPlan, isEmpty); // выключили — всё отменено
  });
}
