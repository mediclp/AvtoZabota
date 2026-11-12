// Уведомления на телефоне (пакет flutter_local_notifications).
//
// Как работает: после любого изменения данных AppStore строит план (core/notification_plan.dart)
// и вызывает [Notifier.reschedule] — все отложенные уведомления отменяются и ставятся заново.
// Так не нужно отслеживать, какое уведомление поменялось.
//
// Где что работает:
//   Android, iOS — уведомления по расписанию (zonedSchedule) и тестовое;
//   браузер      — только тестовое: отложенные уведомления в вебе пакет не поддерживает.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/notification_plan.dart';

/// Интерфейс — чтобы в тестах подставить заглушку вместо настоящего плагина.
abstract class Notifier {
  /// Можно ли ставить уведомления по расписанию на этой платформе.
  bool get canSchedule;
  Future<void> init();

  /// Спросить разрешение у пользователя. true — разрешил.
  Future<bool> requestPermission();
  Future<void> reschedule(List<PlannedNotification> plan);
  Future<void> showTest(String title, String body);
}

/// Ничего не делает: для тестов и платформ без уведомлений.
class NoopNotifier implements Notifier {
  List<PlannedNotification> lastPlan = const [];
  @override
  bool get canSchedule => false;
  @override
  Future<void> init() async {}
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> reschedule(List<PlannedNotification> plan) async => lastPlan = plan;
  @override
  Future<void> showTest(String title, String body) async {}
}

class LocalNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  // Канал уведомлений Android: пользователь видит его название в настройках приложения.
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'maintenance_reminders',
      'Напоминания о ТО',
      channelDescription: 'Сроки замены масла, фильтров, свечей и смены шин',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  @override
  bool get canSchedule =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<void> init() async {
    try {
      if (canSchedule) {
        // Часовой пояс телефона нужен, чтобы «10:00» было по местному времени.
        tzdata.initializeTimeZones();
        final local = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(local.identifier));
      }
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              // Разрешение спрашиваем не при запуске, а когда пользователь включит уведомления.
              iOS: DarwinInitializationSettings(
                requestAlertPermission: false,
                requestBadgePermission: false,
                requestSoundPermission: false,
              ),
            ),
          ) ??
          false;
    } catch (e) {
      debugPrint('Уведомления не инициализированы: $e');
      _ready = false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    if (kIsWeb) {
      return await _plugin.resolvePlatformSpecificImplementation<WebFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false,
      TargetPlatform.iOS => await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false,
      _ => false,
    };
  }

  @override
  Future<void> reschedule(List<PlannedNotification> plan) async {
    if (!_ready || !canSchedule) return;
    await _plugin.cancelAllPendingNotifications();
    for (final p in plan) {
      await _plugin.zonedSchedule(
        id: p.id,
        title: p.title,
        body: p.body,
        scheduledDate: tz.TZDateTime.from(p.at, tz.local),
        notificationDetails: _details,
        // Неточное время (±несколько минут) не требует особого разрешения на «точные будильники».
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  @override
  Future<void> showTest(String title, String body) async {
    if (!_ready) return;
    await _plugin.show(id: 0, title: title, body: body, notificationDetails: _details);
  }
}
