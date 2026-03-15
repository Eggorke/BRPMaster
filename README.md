# BRPMaster

> Разработано для гильдии **BELUGA** — Nordanaar, Turtle WoW
> Developed for guild **BELUGA** — Nordanaar, Turtle WoW

**Автор / Author:** Eggorkus

---

## English

### Overview

BRPMaster is an all-in-one EP/GP DKP loot distribution addon for WoW 1.12. It combines a Master Looter bidding interface with a full guild DKP manager, replacing two separate addons (BRPBT and BRPBidHelper) in a single package.

### Features

- **Master Looter window** — collects whisper bids, displays EP/GP, auto-calculates 2nd-price auction winner, countdown timer, one-click award with DKP deduction
- **Player DKP Manager** — browse all guild members, filter by class or raid-only, sort by name, manually adjust individual EP/GP
- **Dual DKP table** — two independent point systems stored in officer notes; switch between them globally across raid
- **Raid-wide operations** — award EP or GP to the entire raid at once; apply percentage decay with auto-zeroing of values below 5
- **Minimap button** — draggable; left-click opens DKP Manager, right-click opens context menu with all major actions
- **Slash commands** — full CLI control (`/brp help` for list)

### Configuring Table Names

Near the top of [BRPMaster.lua](BRPMaster.lua) (lines 20–21) you will find two variables:

```lua
local TABLE_EP_NAME = "NAXX"
local TABLE_GP_NAME = "KARA"
```

Change these strings to rename the two DKP systems everywhere in the UI (column headers, buttons, announcements, etc.). For example:

```lua
local TABLE_EP_NAME = "NAXX"   -- rename to any label, e.g. "EP" or "RAID1"
local TABLE_GP_NAME = "AQ40"   -- rename to any label, e.g. "GP" or "RAID2"
```

> These names are purely cosmetic — the underlying data keys remain `"EP"` and `"GP"` internally.

### Data Storage

EP/GP values are stored in guild member **officer notes** in the format `{EP:GP}`, for example `{150:200}`. Existing note text is preserved.

### Slash Commands

| Command | Description |
|---|---|
| `/brp` | Toggle loot window (ML) or DKP Manager |
| `/brp table naxx\|kara` | Switch active DKP table |
| `/brp ep <amount>` | Award EP to entire raid |
| `/brp ep <name> <amount>` | Award/deduct EP for a player |
| `/brp gp <amount>` | Award GP to entire raid |
| `/brp gp <name> <amount>` | Award/deduct GP for a player |
| `/brp decay <percent>` | Apply decay to all members |
| `/brp dkp <name>` | Show a player's current EP/GP |
| `/brp standings` | Dump full standings to chat |
| `/brp time <seconds>` | Set bid duration |
| `/brp refresh` | Rebuild guild cache |
| `/brp help` | Show help |

### Requirements

- WoW client 1.12 (Turtle WoW / Vanilla)
- Must be Guild Officer or have officer note write access to modify EP/GP values

### Author

**Eggorkus** — v1.0

---

## Русский

### Описание

BRPMaster — это комплексный аддон управления лутом по системе EP/GP DKP для WoW 1.12. Объединяет интерфейс мастера лута с полным менеджером DKP гильдии, заменяя два отдельных аддона (BRPBT и BRPBidHelper) в одном пакете.

### Возможности

- **Окно мастера лута** — собирает биды в вишперах, отображает EP/GP участников, автоматически определяет победителя по правилу 2nd-price аукциона, таймер обратного отсчёта, присвоение предмета одной кнопкой с автоматическим списанием DKP
- **Менеджер DKP игроков** — просмотр всех членов гильдии, фильтрация по классу или только по рейду, сортировка по имени, ручная корректировка EP/GP отдельных игроков
- **Двойная таблица DKP** — две независимые системы очков, хранимые в офицерских заметках; переключение сразу для всего рейда
- **Операции на весь рейд** — начисление EP или GP сразу всему рейду; применение процентного распада с автоматическим обнулением значений ниже 5
- **Кнопка на миникарте** — перетаскиваемая; левый клик открывает менеджер DKP, правый клик — контекстное меню со всеми основными действиями
- **Слеш-команды** — полное управление через командную строку (`/brp help`)

### Настройка названий таблиц

В начале файла [BRPMaster.lua](BRPMaster.lua) (строки 20–21) находятся две переменные:

```lua
local TABLE_EP_NAME = "NAXX"
local TABLE_GP_NAME = "KARA"
```

Измените эти строки, чтобы переименовать обе системы DKP во всём интерфейсе (заголовки колонок, кнопки, объявления и т.д.). Например:

```lua
local TABLE_EP_NAME = "NAXX"   -- любое название, например "EP" или "РЕЙД1"
local TABLE_GP_NAME = "AQ40"   -- любое название, например "GP" или "РЕЙД2"
```

> Названия влияют только на отображение — внутренние ключи данных остаются `"EP"` и `"GP"`.

### Хранение данных

Значения EP/GP хранятся в **офицерских заметках** членов гильдии в формате `{EP:GP}`, например `{150:200}`. Существующий текст заметки при этом сохраняется.

### Слеш-команды

| Команда | Описание |
|---|---|
| `/brp` | Открыть/закрыть окно лута (ML) или менеджер DKP |
| `/brp table naxx\|kara` | Переключить активную таблицу DKP |
| `/brp ep <количество>` | Начислить EP всему рейду |
| `/brp ep <имя> <количество>` | Начислить/снять EP у игрока |
| `/brp gp <количество>` | Начислить GP всему рейду |
| `/brp gp <имя> <количество>` | Начислить/снять GP у игрока |
| `/brp decay <процент>` | Применить распад ко всем членам |
| `/brp dkp <имя>` | Показать текущие EP/GP игрока |
| `/brp standings` | Вывести общий рейтинг в чат |
| `/brp time <секунды>` | Установить длительность бида |
| `/brp refresh` | Обновить кэш гильдии |
| `/brp help` | Показать справку |

### Требования

- WoW клиент 1.12 (Turtle WoW / Vanilla)
- Должен быть офицером гильдии или иметь права на запись в офицерские заметки для изменения EP/GP

### Автор

**Eggorkus** — v1.0
