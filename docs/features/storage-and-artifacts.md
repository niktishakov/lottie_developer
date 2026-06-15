# Feature: Local Storage and Artifacts

## Purpose

Локальное хранилище отвечает за persistence импортированных анимаций и метаданных библиотеки, без backend dependency.

## Текущая модель данных

1. Файлы хранятся в `Documents/LottieAnimations`.
2. Каждый импорт сохраняется как новый файл `UUID.json`.
3. Метаданные библиотеки:
   - `metadata.json` (primary);
   - `metadata.backup.json` (backup).
4. Модель item:
   - `id`;
   - `name`;
   - `fileName`;
   - `dateAdded`;
   - `isFavorite`.

## Поддерживаемые операции

1. `importAnimation(from sourceURL)`
2. `importAnimation(data: name:)`
3. `toggleFavorite`
4. `rename`
5. `delete`
6. `fileURL(for:)`
7. `loadMetadataIfNeeded` с fallback на backup
8. `loadDemoAnimationIfNeeded` (seed demo только один раз через `UserDefaults`)

## Валидация импорта (as-is)

Перед сохранением выполняется базовая проверка JSON:

1. parse в объект;
2. наличие ключей `v`, `w`, `h`, `layers`.

Если проверка не проходит, возвращается `ImportError.invalidLottieJSON`.

## Надежность persistence (as-is)

1. Metadata пишется через temp file (`metadata.tmp.json`) и move.
2. Перед перезаписью primary делается backup предыдущего metadata.
3. При corruption primary читается backup и автоматически восстанавливается primary.

## Ограничения модели артефактов (as-is)

1. Нет сущности `SourceArtifact` с типом источника и provenance.
2. Нет `DraftArtifact` как отдельного слоя от исходника.
3. Нет immutable `ArtifactRevision` и lineage.
4. Нет rollback pointer на уровне данных.
5. Нет `ReadyCandidate` и `ReadyLottie` артефактов.
6. Нет checksum/release manifest.
7. Нет сохранения `QAReport`.

## Связь с `core-pipeline.md`

1. Есть локальная база для будущего revision store.
2. Текущая схема не соответствует production-spec по state machine и immutable versioning.
3. Для релиза по spec нужен апгрейд storage-модели, а не только UI.
