// План уведомлений: какие напоминания показать на телефоне и когда.
//
// Чистая логика — без плагина уведомлений, её проверяют тесты. Отправкой занимается
// lib/data/notifications.dart: после любого изменения данных он отменяет все
// запланированные уведомления и ставит заново по этому плану.
import 'format.dart';
import 'models.dart';

/// iOS хранит не больше 64 отложенных уведомлений на приложение — берём ближайшие с запасом.
const maxPlannedNotifications = 50;

/// Если напоминание на сегодня, а время уведомлений уже прошло, — показать через минуту.
const lateTodayDelay = Duration(minutes: 1);

/// Позже этого часа «опоздавшие» сегодняшние напоминания не показываем — чтобы не будить ночью.
const lateTodayUntilHour = 21;

class PlannedNotification {
  final int id; // уникален в пределах одного плана
  final String key; // «машина|расходник|дата» — чтобы не повторять опоздавшие сегодняшние
  final DateTime at; // локальное время показа
  final String title;
  final String body;
  final bool lateToday; // сегодняшнее, поставленное вне обычного времени
  const PlannedNotification(this.id, this.key, this.at, this.title, this.body, {this.lateToday = false});
}

String notificationKey(Car car, ScheduleItem item, DateTime reminderDay) =>
    '${car.id}|${item.consumable.id}|${isoDate(reminderDay)}';

String _title(ScheduleItem s) => switch (s.action) {
      ServiceAction.seasonalSwap => 'Пора менять шины',
      ServiceAction.inspect => 'Скоро проверка на ТО',
      ServiceAction.replace => 'Скоро замена на ТО',
    };

String _body(Car car, ScheduleItem s, DateTime reminderDay) {
  final text = reminderText(car, s);
  if (s.action == ServiceAction.seasonalSwap || s.dueDate == null) return text;
  return '$text (${fmtDaysLeft(daysBetween(reminderDay, s.dueDate!))})';
}

/// Строит план по графикам всех машин.
///
/// [now] — текущее локальное время; [hour]:[minute] — во сколько присылать;
/// [lateToday] — «опоздавшие» сегодняшние напоминания, уже поставленные на «через минуту»:
/// ключ → на какое время поставили. Если время ещё не наступило, ставим на него же
/// (план пересобирается при каждом изменении данных); если наступило — уже показали.
List<PlannedNotification> planNotifications(
  List<(Car, List<ScheduleItem>)> schedules,
  DateTime now, {
  int hour = 10,
  int minute = 0,
  Map<String, DateTime> lateToday = const {},
}) {
  final today = dateOnly(now);
  final candidates = <(DateTime, String, String, String, bool)>[];
  for (final (car, items) in schedules) {
    for (final item in items) {
      for (final r in item.reminders) {
        var at = DateTime(r.year, r.month, r.day, hour, minute);
        final key = notificationKey(car, item, r);
        if (!at.isAfter(now)) {
          // время уже прошло: только сегодняшние, только днём и только один раз
          if (r != today) continue;
          final earlier = lateToday[key];
          if (earlier != null) {
            if (!earlier.isAfter(now)) continue; // уже показали
            at = earlier; // ещё ждёт — оставляем то же время
          } else {
            if (now.hour >= lateTodayUntilHour) continue;
            at = now.add(lateTodayDelay);
          }
        }
        final late = r == today && at != DateTime(r.year, r.month, r.day, hour, minute);
        candidates.add((at, key, _title(item), _body(car, item, r), late));
      }
    }
  }
  candidates.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final (i, (at, key, title, body, late)) in candidates.take(maxPlannedNotifications).indexed)
      PlannedNotification(i + 1, key, at, title, body, lateToday: late),
  ];
}
