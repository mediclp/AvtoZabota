// Экран 6: уведомления — включить, выбрать время, проверить; ближайшие напоминания по всем машинам.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../data/store.dart';
import 'widgets.dart';

class RemindersScreen extends StatelessWidget {
  const RemindersScreen({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final reminders = store.upcomingReminders();
        final cs = Theme.of(context).colorScheme;
        final (h, m) = store.notifyTime;
        return Scaffold(
          appBar: AppBar(title: const Text('Напоминания')),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            Card(
              child: Column(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Уведомления на телефоне'),
                  subtitle: Text(store.canScheduleNotifications
                      ? 'Пришлём за 7 и за 1 день до срока'
                      : 'В браузере напоминания по расписанию не работают — только в приложении на телефоне. '
                          'Здесь можно проверить тестовое уведомление.'),
                  value: store.notificationsEnabled,
                  onChanged: (v) => _toggle(context, v),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Время уведомлений'),
                  trailing: Text('$h:${m.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.titleMedium),
                  enabled: store.notificationsEnabled,
                  onTap: () => _pickTime(context, h, m),
                ),
                ListTile(
                  leading: const Icon(Icons.send_outlined),
                  title: const Text('Отправить тестовое уведомление'),
                  enabled: store.notificationsEnabled,
                  onTap: store.sendTestNotification,
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text('Ближайшие 2 месяца', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (reminders.isEmpty) const ListTile(title: Text('Напоминаний нет')),
            for (final r in reminders)
              Card(
                child: ListTile(
                  leading: Icon(statusIcon(r.item.status), color: statusColor(r.item.status, cs)),
                  title: Text(reminderText(r.car, r.item)),
                  subtitle: Text('Уведомление ${fmtDate(r.on)} (${fmtDaysLeft(daysBetween(store.today, r.on))})'),
                ),
              ),
          ]),
        );
      },
    );
  }

  Future<void> _toggle(BuildContext context, bool enabled) async {
    final ok = await store.setNotificationsEnabled(enabled);
    if (!ok && context.mounted) {
      showError(
          context,
          kIsWeb
              ? 'Браузер не разрешил уведомления. Разрешите их для этого сайта (значок слева от адреса).'
              : 'Нет разрешения на уведомления. Разрешите их в настройках телефона для «АвтоЗабота».');
    }
  }

  Future<void> _pickTime(BuildContext context, int h, int m) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: h, minute: m));
    if (t != null) await store.setNotifyTime(t.hour, t.minute);
  }
}
