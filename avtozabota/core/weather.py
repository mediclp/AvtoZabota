"""Прогноз погоды для сезонной смены шин.

Источник — Open-Meteo (https://open-meteo.com): бесплатно, без ключа, для некоммерческих
проектов до 10 000 запросов в день. Приложению хватит одного запроса в день на машину.

Правило: шины пора менять, когда среднесуточная температура устойчиво (STABLE_DAYS дней
подряд) перешла через +7 °C. Для летних шин дополнительно ждём, чтобы ночью не было заморозков.
"""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Sequence

from .models import TireSeason

API_URL = "https://api.open-meteo.com/v1/forecast"
THRESHOLD_C = 7.0
STABLE_DAYS = 5
PAST_DAYS = 7
FORECAST_DAYS = 16
# Защита от аномалий: майское похолодание не повод ставить зимние, оттепель в январе — не повод снимать.
WINTER_SIGNAL_MONTHS = range(8, 13)   # август–декабрь
SUMMER_SIGNAL_MONTHS = range(2, 7)    # февраль–июнь


@dataclass(frozen=True)
class DailyTemp:
    on: date
    mean_c: float
    min_c: float


def parse_open_meteo(payload: dict) -> list[DailyTemp]:
    """Ответ Open-Meteo → список дней. Дни без данных (null) пропускаются."""
    daily = payload["daily"]
    rows = zip(daily["time"], daily["temperature_2m_mean"], daily["temperature_2m_min"])
    return [DailyTemp(date.fromisoformat(t), float(mean), float(mn))
            for t, mean, mn in rows if mean is not None and mn is not None]


def fetch_daily_temps(lat: float, lon: float, timeout: float = 10.0) -> list[DailyTemp]:
    """7 прошедших дней + 16 дней прогноза. Бросает OSError/ValueError при сбое — тогда
    вызывающий код просто считает по календарю."""
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError("Некорректные координаты")
    query = urllib.parse.urlencode({
        "latitude": round(lat, 2), "longitude": round(lon, 2),   # ~1 км: точнее не нужно
        "daily": "temperature_2m_mean,temperature_2m_min",
        "timezone": "auto", "past_days": PAST_DAYS, "forecast_days": FORECAST_DAYS,
    })
    req = urllib.request.Request(f"{API_URL}?{query}", headers={"User-Agent": "AvtoZabota/0.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return parse_open_meteo(json.load(resp))


def _fits(day: DailyTemp, target: TireSeason) -> bool:
    if target is TireSeason.WINTER:
        return day.mean_c <= THRESHOLD_C
    return day.mean_c >= THRESHOLD_C and day.min_c >= 0


def swap_signal(temps: Sequence[DailyTemp], target: TireSeason, not_before: date | None = None) -> date | None:
    """Первый день серии из STABLE_DAYS подряд дней, когда погода требует комплект target.

    not_before — отбросить дни раньше этой даты (например, до прошлой смены шин).
    """
    months = WINTER_SIGNAL_MONTHS if target is TireSeason.WINTER else SUMMER_SIGNAL_MONTHS
    days = sorted((d for d in temps if not_before is None or d.on >= not_before), key=lambda d: d.on)
    run_start, run_len, prev = None, 0, None
    for d in days:
        contiguous = prev is not None and d.on - prev == timedelta(days=1)
        if _fits(d, target):
            if not contiguous or run_len == 0:
                run_start, run_len = d.on, 0
            run_len += 1
            if run_len >= STABLE_DAYS and run_start.month in months:
                return run_start
        else:
            run_len = 0
        prev = d.on
    return None


def covers(temps: Sequence[DailyTemp], today: date) -> bool:
    """Прогноз свежий: в нём есть сегодняшний день или позже."""
    return any(d.on >= today for d in temps)
