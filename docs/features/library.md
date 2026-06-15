# Feature: Library (Import + Catalog)

## Purpose

Библиотека является primary entrypoint: пользователь видит все локальные анимации, ищет их, импортирует новые JSON и открывает превью для QA.

## Что поддерживается сейчас

1. `Empty state` и `List state` на одном экране.
2. Поиск по имени (`localizedCaseInsensitiveContains`).
3. Нижний action bar:
   - поле поиска;
   - кнопка `+` c `Menu`.
4. Зона касания `+` зафиксирована как круг `44x44` с `contentShape(Circle())`.
5. Импорт из 3 источников:
   - `Files` (`.json` + `.lottie`);
   - `URL` (скачивание по прямой ссылке);
   - `Clipboard` (JSON-текст).
6. Навигация в превью по tap на item.
7. Операции над item:
   - favorite / unfavorite;
   - delete;
   - context menu и swipe actions.
8. Hero-card с CTA к импорту/апгрейду.
9. Paywall sheet для non-pro пользователя.

## Детализация по флоу

## 1) Import from Files

1. Выбор нескольких файлов через `fileImporter`.
2. Каждый файл импортируется последовательно.
3. На ошибке показывается alert, остальные файлы продолжают импортироваться.

## 2) Import from URL

1. Ввод URL в alert.
2. Загрузка через `URLSession` с таймаутами:
   - `timeoutIntervalForRequest = 30s`;
   - `timeoutIntervalForResource = 60s`.
3. Результат сохраняется как локальный JSON.

## 3) Import from Clipboard

1. Берется `UIPasteboard.general.string`.
2. Валидируется как JSON-текст.
3. Имя можно задать вручную; иначе используется timestamp-based default name.

## 4) Pro gating

1. Все import entrypoints (`Files`, `URL`, `Clipboard`) доступны только при `purchaseStore.isPro == true`.
2. Для free пользователя на любой import intent открывается paywall.

## 5) Ошибки и UX feedback

1. Единый alert для import/download/validation ошибок.
2. Отдельные состояния `isImporting` и `isDownloading` блокируют повторные действия.
3. При фильтре без совпадений показывается `ContentUnavailableView.search`.

## Технические ограничения (as-is)

1. Нет сортировки и группировки библиотеки.
2. Нет тегов/папок/коллекций.
3. Нет дедупликации импортов.
4. Нет background import queue с прогрессом.
5. URL import не проверяет MIME/content-type, только факт загрузки данных.
6. Import pipeline ориентирован на JSON, не на SVG.

## Связь с `core-pipeline.md`

1. Покрывает часть `Stage 1 Source Intake` только для JSON источников.
2. Не покрывает multi-source intake (`SVG`, `Prompt/Spec`).
3. Не содержит `Stage 2 Canonicalization` и formal gate orchestration.
