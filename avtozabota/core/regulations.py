"""Загрузка справочника регламентов из JSON и подбор регламента для авто."""
from __future__ import annotations

import json
from pathlib import Path

from .models import Action, Consumable, Engine, Regulation, RegulationItem

GENERIC_ID = "generic"
# Справочники лежат в Flutter-приложении (app/assets/data) — один источник для прототипа и приложения.
DEFAULT_PATH = Path(__file__).resolve().parents[2] / "app" / "assets" / "data" / "regulations.json"


def _parse_item(i: dict, base: dict | None = None) -> RegulationItem:
    """Пункт регламента; вариант для двигателя (base задан) берёт расходник и действие у основного."""
    src = base or i
    return RegulationItem(
        consumable=Consumable(src["consumable"]),
        action=Action(src["action"]),
        interval_km=i.get("interval_km"),
        interval_months=i.get("interval_months"),
        sourced=i.get("sourced", False),
        note=i.get("note", ""),
        by_engine=() if base else tuple(
            (eid, _parse_item(o, base=i)) for eid, o in i.get("by_engine", {}).items()
        ),
    )


def load_regulations(path: Path = DEFAULT_PATH) -> dict[str, Regulation]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    result: dict[str, Regulation] = {}
    for r in raw["regulations"]:
        if r["id"] in result:
            raise ValueError(f"Повтор id регламента: {r['id']}")
        items = tuple(_parse_item(i) for i in r["items"])
        consumables = [i.consumable for i in items]
        if len(consumables) != len(set(consumables)):
            raise ValueError(f"{r['id']}: расходник указан дважды")
        result[r["id"]] = Regulation(
            id=r["id"], make=r["make"], model=r["model"],
            year_from=r.get("year_from"), year_to=r.get("year_to"),
            items=items, source=r.get("source", ""),
            engines=tuple(Engine(e["id"], e["title"]) for e in r.get("engines", [])),
        )
    if GENERIC_ID not in result:
        raise ValueError("В справочнике нет общего регламента 'generic'")
    return result


def catalog(regs: dict[str, Regulation]) -> dict[str, list[str]]:
    """Марки и модели для выпадающих списков на экране «Добавить авто»."""
    result: dict[str, set[str]] = {}
    for reg in regs.values():
        if reg.id != GENERIC_ID:
            result.setdefault(reg.make, set()).add(reg.model)
    return {make: sorted(models) for make, models in sorted(result.items())}


def find_regulation(regs: dict[str, Regulation], make: str, model: str, year: int) -> Regulation:
    """Регламент модели, а если модели нет в справочнике — общий."""
    for reg in regs.values():
        if reg.id != GENERIC_ID and reg.matches(make, model, year):
            return reg
    return regs[GENERIC_ID]
