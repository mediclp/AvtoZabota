"""Расчёт графика ТО: когда менять каждый расходник и когда слать напоминания.

Правило: срок наступает по пробегу ИЛИ по времени — что раньше.
Чтобы напомнить «за 7 дней» о сроке по пробегу, пробег переводится в дату
через средний пробег в день (км/день).
"""
from __future__ import annotations

import calendar
import math
from datetime import date, timedelta
from enum import Enum

from .models import (Car, Consumable, OdometerReading, Regulation, RegulationItem, ScheduleItem,
                     ServiceRecord, Status, Trigger)
from typing import Sequence

from .tires import tire_item
from .weather import DailyTemp

DEFAULT_KM_PER_DAY = 41.0          # ≈ 15 000 км в год, если о водителе ничего не известно
DAYS_PER_MONTH = 30.44
RATE_WINDOW_DAYS = 365             # средний пробег считаем по последнему году
MIN_RATE_SPAN_DAYS = 14            # меньше двух недель данных — слишком шумно
SOON_DAYS = 7
SOON_KM = 500
REMIND_BEFORE_DAYS = (7, 1)


class RateSource(str, Enum):
    READINGS = "readings"    # посчитан по показаниям пробега
    DECLARED = "declared"    # со слов пользователя «км в месяц»
    DEFAULT = "default"      # среднее по стране


def add_months(d: date, months: int) -> date:
    """31 января + 1 месяц = 28/29 февраля."""
    y, m = divmod(d.month - 1 + months, 12)
    year, month = d.year + y, m + 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def _known_points(car: Car, today: date) -> list[OdometerReading]:
    return [p for p in car.observations() if p.on <= today]


def estimate_km_per_day(car: Car, today: date) -> tuple[float, RateSource]:
    points = _known_points(car, today)
    if points:
        latest = points[-1]
        window = [p for p in points if (latest.on - p.on).days <= RATE_WINDOW_DAYS]
        first = window[0]
        span = (latest.on - first.on).days
        if span >= MIN_RATE_SPAN_DAYS:
            return max(0.0, (latest.km - first.km) / span), RateSource.READINGS
    if car.km_per_month_declared is not None:
        return car.km_per_month_declared / DAYS_PER_MONTH, RateSource.DECLARED
    return DEFAULT_KM_PER_DAY, RateSource.DEFAULT


def estimate_odometer(car: Car, on: date, km_per_day: float) -> int | None:
    points = _known_points(car, on)
    if not points:
        return None
    latest = points[-1]
    return round(latest.km + km_per_day * (on - latest.on).days)


def last_service(car: Car, consumable: Consumable, today: date) -> ServiceRecord | None:
    done = [s for s in car.services if consumable in s.consumables and s.on <= today]
    # Самая поздняя по дате и пробегу; при полном равенстве — добавленная позже.
    return max(reversed(done), key=lambda s: (s.on, s.odometer_km), default=None)


def schedule_item(car: Car, item: RegulationItem, today: date, km_per_day: float) -> ScheduleItem:
    last = last_service(car, item.consumable, today)
    if last is None:
        return ScheduleItem(item.consumable, item.action, Status.UNKNOWN)

    latest = _known_points(car, today)[-1]
    current_km = estimate_odometer(car, today, km_per_day)

    due_km = due_by_km = remaining_km = None
    if item.interval_km is not None:
        due_km = last.odometer_km + item.interval_km
        remaining_km = due_km - current_km
        if km_per_day > 0:
            due_by_km = latest.on + timedelta(days=math.ceil((due_km - latest.km) / km_per_day))
        elif due_km <= latest.km:
            due_by_km = latest.on
        # машина стоит (0 км/день) и до срока по пробегу далеко — даты по пробегу нет

    due_by_time = add_months(last.on, item.interval_months) if item.interval_months is not None else None

    candidates = [(d, t) for d, t in ((due_by_km, Trigger.KM), (due_by_time, Trigger.TIME)) if d is not None]
    due_date, trigger = min(candidates, key=lambda c: c[0]) if candidates else (None, None)
    if due_date is None and due_km is not None:
        trigger = Trigger.KM
    remaining_days = (due_date - today).days if due_date is not None else None

    overdue = (remaining_km is not None and remaining_km <= 0) or (remaining_days is not None and remaining_days < 0)
    soon = (remaining_km is not None and remaining_km <= SOON_KM) or (
        remaining_days is not None and remaining_days <= SOON_DAYS)
    status = Status.OVERDUE if overdue else Status.SOON if soon else Status.OK

    reminders: tuple[date, ...] = ()
    if due_date is not None and not overdue:
        reminders = tuple(sorted({due_date - timedelta(days=d) for d in REMIND_BEFORE_DAYS
                                  if due_date - timedelta(days=d) >= today}))

    return ScheduleItem(
        consumable=item.consumable, action=item.action, status=status, last_service=last,
        due_km=due_km, due_date=due_date, due_by_time=due_by_time, due_by_km_estimated=due_by_km,
        trigger=trigger, remaining_km=remaining_km, remaining_days=remaining_days, reminders=reminders,
    )


_STATUS_ORDER = {Status.OVERDUE: 0, Status.SOON: 1, Status.UNKNOWN: 2, Status.OK: 3}


def build_schedule(car: Car, regulation: Regulation, today: date,
                   forecast: Sequence[DailyTemp] | None = None) -> list[ScheduleItem]:
    """График по всем расходникам: сначала просроченные, затем ближайшие.

    forecast — температура по дням для места машины (core.weather.fetch_daily_temps);
    без него шины считаются по календарю.
    """
    if regulation.id != car.regulation_id:
        raise ValueError("Регламент не соответствует автомобилю")
    km_per_day, _ = estimate_km_per_day(car, today)
    items = [schedule_item(car, it, today, km_per_day) for it in regulation.items_for(car.engine_id)]
    tires = tire_item(car, today, forecast)
    if tires is not None:
        items.append(tires)
    return sorted(items, key=lambda s: (_STATUS_ORDER[s.status], s.due_date or date.max))
