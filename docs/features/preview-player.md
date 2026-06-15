# Feature: Preview Player (Runtime QA)

## Purpose

Экран превью дает ручной QA цикл для отдельной анимации: воспроизведение, диапазон, скорость, loop и базовые file actions.

## Что поддерживается сейчас

1. Адаптивный layout:
   - compact: canvas сверху + карточки контролов;
   - regular: canvas + боковая панель контролов.
2. Основной canvas с checkerboard background.
3. Fullscreen режим превью через sheet.
4. Прогресс:
   - slider `0...1`;
   - процент и статус `Playing/Paused`.
5. Playback controls:
   - rewind до `fromProgress`;
   - play/pause;
   - fast-forward до `toProgress`;
   - loop on/off.
6. `Playback Range` через dual-thumb `RangeSlider`.
7. Скорость:
   - slider `0.25x...3x`;
   - пресеты `[0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]`.
8. Toolbar menu:
   - rename;
   - favorite toggle;
   - file info;
   - share file URL.
9. Keyboard shortcut `Space` для play/pause.

## Runtime логика Lottie (as-is)

1. Загрузка `LottieAnimation.filepath(fileURL.path)`.
2. `PlaybackState` синхронизируется с `LottieAnimationView`.
3. Прогресс синхронизируется таймером ~60 FPS (`realtimeAnimationProgress`).
4. При loop и старте из середины диапазона сначала доигрывается текущий сегмент, затем включается loop по заданному range.
5. При изменении `fromProgress/toProgress` текущий прогресс клампится в новый диапазон.

## Что это дает для QA сейчас

1. Ручная проверка тайминга на разных скоростях.
2. Ручная проверка корректности playback range.
3. Ручная проверка loop-поведения и визуальных артефактов.
4. Быстрый inspect данных файла (дата, размер, имя, favorite).

## Ограничения (as-is)

1. Нет автоматического `QAReport` (findings/severity).
2. Нет snapshot/visual diff между ревизиями.
3. Нет runtime gate результатов в формальном виде `pass/fail`.
4. Нет device matrix проверки (разные рендереры/платформы).
5. Нет автодиагностики unsupported Lottie features.

## Связь с `core-pipeline.md`

1. Частично покрывает `Stage 5 Motion Semantic Gate` через manual QA.
2. Частично покрывает `Stage 6 Runtime Gate` через локальный preview.
3. Не покрывает formal deterministic gate contracts и отчетность по gate results.
