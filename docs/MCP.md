# lottie-mcp

MCP-сервер (stdio) для управления Lottie Developer извне. Хранилище общее с Mac-приложением
(`~/Library/Application Support/LottieDeveloperMac`), приложение подхватывает изменения на лету.

## Сборка

```bash
xcodebuild -project LottieDeveloper.xcodeproj -scheme lottie-mcp -configuration Release -derivedDataPath build/dd build
```

Бинарник: `build/dd/Build/Products/Release/lottie-mcp`.

## Подключение (Claude Code)

```bash
claude mcp add lottie-developer -- /ABS/PATH/build/dd/Build/Products/Release/lottie-mcp
```

## Инструменты

get_guide, list_projects, get_project, create_project, rename_project, delete_project,
replace_geometry, get_geometry, validate_spec, create_version, create_version_from_lottie,
list_versions, get_version, diff_versions, restore_version, delete_version, set_favourite,
set_version_note, export, show_in_app, render_frame (PNG-кадры: frame | progress | frames[] | count, до 16 шт.), get_app_state (что сейчас в приложении), apply_overrides (цвет/прозрачность/скрытие слоёв → новая версия). show_in_app умеет frame, layer и tap ([x, y] в координатах композиции — как клик по холсту).

Версии: UUID, `v3`, `3` или `latest`. `base_version` — строить поверх версии.
