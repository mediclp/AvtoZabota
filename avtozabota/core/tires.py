"""Сезонная смена шин.

Шины меняют не по пробегу, а по погоде: когда среднесуточная температура устойчиво
переходит через +5…+7 °C. Без прогноза погоды (это не MVP) используем окна дат
по климатическим зонам.

Закон (ТР ТС 018/2011, прил. 8, п. 5.5): зимние шины обязательны в декабре–феврале,
шипованные шины запрещены в июне–августе.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from typing import Sequence

from . import weather
from .models import (Action, Car, Consumable, ScheduleItem, ServiceRecord, Status, TireSeason,
                     TireSetup, Trigger)
from .weather import DailyTemp

MonthDay = tuple[int, int]

WINTER_TIRES_REQUIRED_FROM: MonthDay = (12, 1)
STUDS_FORBIDDEN_FROM: MonthDay = (6, 1)
REMIND_BEFORE_WINDOW_DAYS = 7
REMIND_BEFORE_LEGAL_DAYS = 7


@dataclass(frozen=True)
class ClimateZone:
    id: str
    title: str
    spring: tuple[MonthDay, MonthDay]   # окно смены на летние
    autumn: tuple[MonthDay, MonthDay]   # окно смены на зимние


# Ориентиры из рекомендаций Минтранса и автоизданий; см. README → «Сезонная смена шин».
CLIMATE_ZONES: dict[str, ClimateZone] = {z.id: z for z in (
    ClimateZone("south", "Юг (Крым, Краснодарский край, Ростов, Ставрополь)",
                spring=((3, 15), (4, 10)), autumn=((11, 1), (11, 30))),
    ClimateZone("center", "Центр, Северо-Запад, Поволжье",
                spring=((4, 1), (4, 25)), autumn=((10, 15), (10, 31))),
    ClimateZone("north_east", "Урал, Сибирь, Север, Дальний Восток",
                spring=((4, 25), (5, 15)), autumn=((9, 20), (10, 15))),
)}


def _window(window: tuple[MonthDay, MonthDay], year: int) -> tuple[date, date]:
    (sm, sd), (em, ed) = window
    return date(year, sm, sd), date(year, em, ed)


def _swap_year(mounted: TireSeason, on: date) -> int:
    """Год окна, в которое этот комплект надо снять.

    Летние, поставленные в январе, относятся к прошлой зиме (уже пора менять);
    поставленные в феврале–декабре снимаются осенью того же года.
    Зимние, поставленные с августа, снимаются весной следующего года; поставленные
    до августа — весной этого года (если весна прошла, пункт сразу просрочен).
    """
    if mounted is TireSeason.SUMMER:
        return on.year - 1 if on.month == 1 else on.year
    return on.year + 1 if on.month >= 8 else on.year


def _illegal_now(target: TireSeason, studded: bool, today: date) -> bool:
    """Езда на текущем комплекте сегодня нарушает ТР ТС."""
    if target is TireSeason.WINTER:          # стоят летние
        return today.month in (12, 1, 2)
    return studded and today.month in (6, 7, 8)   # стоят зимние


def last_tire_swap(car: Car, today: date) -> ServiceRecord | None:
    swaps = [s for s in car.services if s.tires_mounted is not None and s.on <= today]
    # При одинаковой дате побеждает запись, добавленная позже (max() вернул бы первую из равных).
    return max(reversed(swaps), key=lambda s: s.on, default=None)


def tire_item(car: Car, today: date, forecast: Sequence[DailyTemp] | None = None) -> ScheduleItem | None:
    """Пункт графика «сменить шины» или None, если напоминать не о чем.

    forecast — температура по дням (core.weather). Если он есть и свежий, срок считается
    по погоде; иначе — по календарным окнам климатической зоны.
    """
    if car.tire_setup is None or car.tire_setup is TireSetup.ALL_SEASON:
        return None
    if car.climate_zone not in CLIMATE_ZONES:
        raise ValueError(f"Неизвестная климатическая зона: {car.climate_zone}")
    zone = CLIMATE_ZONES[car.climate_zone]

    last = last_tire_swap(car, today)
    if last is None:   # не знаем, какие шины стоят, — интерфейс спросит
        return ScheduleItem(Consumable.TIRES, Action.SEASONAL_SWAP, Status.UNKNOWN)

    if last.tires_mounted is TireSeason.SUMMER:
        target, window = TireSeason.WINTER, zone.autumn
    else:
        target, window = TireSeason.SUMMER, zone.spring
    start, end = _window(window, _swap_year(last.tires_mounted, last.on))

    legal = None
    if target is TireSeason.WINTER:
        legal = date(end.year, *WINTER_TIRES_REQUIRED_FROM)
    elif car.winter_studded:
        legal = date(end.year, *STUDS_FORBIDDEN_FROM)

    illegal = _illegal_now(target, car.winter_studded, today)
    legal_reminder = {legal - timedelta(days=REMIND_BEFORE_LEGAL_DAYS)} if legal else set()

    if forecast and weather.covers(forecast, today):
        return _by_weather(last, target, legal, illegal, legal_reminder, forecast, today)

    if today > end or illegal:
        status = Status.OVERDUE
    elif today >= start - timedelta(days=REMIND_BEFORE_WINDOW_DAYS):
        status = Status.SOON
    else:
        status = Status.OK

    candidates = {start - timedelta(days=REMIND_BEFORE_WINDOW_DAYS), start} | legal_reminder
    reminders = tuple(sorted(d for d in candidates if d >= today))

    return ScheduleItem(
        consumable=Consumable.TIRES, action=Action.SEASONAL_SWAP, status=status,
        last_service=last, due_date=end, due_by_time=end, trigger=Trigger.TIME,
        remaining_days=(end - today).days, reminders=reminders,
        tires_to_mount=target, window_start=start, legal_deadline=legal,
    )


WEATHER_WINDOW_DAYS = 7      # сколько дней после начала похолодания/потепления даём на смену
WEATHER_HEADS_UP_DAYS = 3    # предупреждение заранее, если смена по прогнозу ещё впереди


def _by_weather(last: ServiceRecord, target: TireSeason, legal: date | None, illegal: bool,
                legal_reminder: set[date], forecast: Sequence[DailyTemp], today: date) -> ScheduleItem:
    signal = weather.swap_signal(forecast, target, not_before=last.on)
    legal_soon = legal is not None and today >= legal - timedelta(days=REMIND_BEFORE_LEGAL_DAYS)

    if signal is None:   # по прогнозу ещё рано — напоминаем только о законе
        status = Status.OVERDUE if illegal else Status.SOON if legal_soon else Status.OK
        return ScheduleItem(
            consumable=Consumable.TIRES, action=Action.SEASONAL_SWAP, status=status,
            last_service=last, trigger=Trigger.WEATHER,
            reminders=tuple(sorted(d for d in legal_reminder if d >= today)),
            tires_to_mount=target, legal_deadline=legal,
        )

    end = signal + timedelta(days=WEATHER_WINDOW_DAYS)
    if today > end or illegal:
        status = Status.OVERDUE
    elif today >= signal - timedelta(days=REMIND_BEFORE_WINDOW_DAYS) or legal_soon:
        status = Status.SOON
    else:
        status = Status.OK
    candidates = {signal - timedelta(days=WEATHER_HEADS_UP_DAYS), signal, max(signal, today)} | legal_reminder
    return ScheduleItem(
        consumable=Consumable.TIRES, action=Action.SEASONAL_SWAP, status=status,
        last_service=last, due_date=end, due_by_time=end, trigger=Trigger.WEATHER,
        remaining_days=(end - today).days,
        reminders=tuple(sorted(d for d in candidates if d >= today)),
        tires_to_mount=target, window_start=signal, legal_deadline=legal,
    )
