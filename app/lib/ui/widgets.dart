// Мелкие общие виджеты: цвет и значок статуса, сообщения об ошибках.
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';

Color statusColor(Status s, ColorScheme cs) => switch (s) {
      Status.overdue => cs.error,
      Status.soon => Colors.orange.shade700,
      Status.ok => Colors.green.shade600,
      Status.unknown => cs.outline,
    };

IconData statusIcon(Status s) => switch (s) {
      Status.overdue => Icons.error,
      Status.soon => Icons.schedule,
      Status.ok => Icons.check_circle,
      Status.unknown => Icons.help,
    };

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final Status status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status, Theme.of(context).colorScheme);
    return Chip(
      avatar: Icon(statusIcon(status), color: color, size: 18),
      label: Text(status.title),
      side: BorderSide(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

void showError(BuildContext context, Object error) {
  final text = error is ArgumentError ? '${error.message}' : '$error';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Поле для целого числа (пробег, год, сумма).
class IntField extends StatelessWidget {
  const IntField({super.key, required this.controller, required this.label, this.required = true, this.suffix, this.validator});
  final TextEditingController controller;
  final String label;
  final bool required;
  final String? suffix;
  final String? Function(int?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder()),
      validator: (text) {
        final t = (text ?? '').replaceAll(' ', '');
        if (t.isEmpty) return required ? 'Заполните поле' : validator?.call(null);
        final v = int.tryParse(t);
        if (v == null || v < 0) return 'Введите целое число';
        return validator?.call(v);
      },
    );
  }
}

int? parseIntField(TextEditingController c) => int.tryParse(c.text.replaceAll(' ', ''));
