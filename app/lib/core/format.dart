// Форматирование для экранов и уведомлений: даты, километры, текст напоминания.
import 'models.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// 12.11.2026
String fmtDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

/// 12.11
String fmtShortDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}';

/// 115 000 км (неразрывные пробелы между разрядами)
String fmtKm(int km) {
  final s = km.abs().toString();
  final buf = StringBuffer(km < 0 ? '−' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '$buf км';
}

/// «через 5 дн.», «сегодня», «3 дн. назад»
String fmtDaysLeft(int days) {
  if (days == 0) return 'сегодня';
  if (days == 1) return 'завтра';
  if (days > 0) return 'через $days дн.';
  return '${-days} дн. назад';
}

/// Короткое название пункта для списка: «Сменить шины на зимние», «Тормозные колодки — проверить».
String itemTitle(ScheduleItem s) {
  if (s.action == ServiceAction.seasonalSwap) {
    return s.tiresToMount == null ? 'Сезонная смена шин' : 'Поставить ${s.tiresToMount!.title.toLowerCase()} шины';
  }
  return s.action == ServiceAction.inspect ? '${s.consumable.title} — проверить' : s.consumable.title;
}

/// Строка с подробностями срока для списка.
String itemDetails(ScheduleItem s) {
  if (s.status == Status.unknown) {
    return s.consumable == Consumable.tires
        ? 'Неизвестно, какие шины стоят — отметьте смену шин'
        : 'Нет данных о последней замене — отметьте, когда меняли';
  }
  final parts = <String>[];
  if (s.action == ServiceAction.seasonalSwap) {
    if (s.windowStart != null) {
      parts.add(s.trigger == Trigger.weather
          ? 'по прогнозу пора с ${fmtShortDate(s.windowStart!)}'
          : 'менять ${fmtShortDate(s.windowStart!)}–${fmtShortDate(s.dueDate!)}');
    } else {
      parts.add('по прогнозу ещё тепло');
    }
    if (s.legalDeadline != null) parts.add('по закону до ${fmtDate(s.legalDeadline!)}');
    return parts.join(' · ');
  }
  if (s.dueDate != null) {
    parts.add('до ${fmtDate(s.dueDate!)} (${fmtDaysLeft(s.remainingDays!)}, ${s.trigger!.title})');
  }
  if (s.remainingKm != null) {
    parts.add(s.remainingKm! > 0 ? 'осталось ${fmtKm(s.remainingKm!)}' : 'пробег превышен на ${fmtKm(-s.remainingKm!)}');
  }
  return parts.join(' · ');
}

/// Текст уведомления: «Lada Vesta: Моторное масло и масляный фильтр — до 10.12.2026».
String reminderText(Car car, ScheduleItem s) {
  final what = itemTitle(s);
  final when = s.action == ServiceAction.seasonalSwap
      ? (s.windowStart != null ? ' — пора с ${fmtDate(s.windowStart!)}' : '')
      : (s.dueDate != null ? ' — до ${fmtDate(s.dueDate!)}' : '');
  return '${car.make} ${car.model}: $what$when';
}
