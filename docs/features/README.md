# Feature Inventory (As-Is) for Lottie Developer

Дата актуализации: 23 February 2026.

Цель папки `docs/features`: зафиксировать текущий реализованный функционал приложения (as-is), чтобы сверить его с target-состоянием из `docs/core-pipeline.md` и построить release backlog без догадок.

## Источники фактов

Функционал ниже описан по текущему коду:

1. `Sources/Views/AnimationLibraryView.swift`
2. `Sources/Views/AnimationPlayerView.swift`
3. `Sources/Views/LottieAnimationUIView.swift`
4. `Sources/Store/AnimationStore.swift`
5. `Sources/Store/PurchaseStore.swift`
6. `Sources/Views/Onboarding/OnboardingView.swift`
7. `Sources/Views/Onboarding/OnboardingPageView.swift`
8. `Sources/Views/Paywall/PaywallView.swift`

## Карта фич (as-is)

1. `docs/features/library.md`  
   Главный экран библиотеки: поиск, импорт entrypoints, список, swipe actions, pro-gating.
2. `docs/features/preview-player.md`  
   Экран превью/плеера: playback controls, range/speed, fullscreen, file info, share.
3. `docs/features/storage-and-artifacts.md`  
   Локальное хранение JSON, metadata backup, import validation, demo seed.
4. `docs/features/monetization-and-entry.md`  
   Onboarding, paywall, StoreKit purchases, ограничения free/pro.
5. `docs/features/release-gaps-vs-core-pipeline.md`  
   Gap-анализ against production-spec из `docs/core-pipeline.md`.
6. `docs/features/implementation-plan.md`  
   Исполняемый backlog: эпики, приоритеты, очередность, DoD и milestone gates.

## Сводка покрытия Core Pipeline (high-level)

| Core Stage (`docs/core-pipeline.md`) | Текущий статус | Комментарий |
| --- | --- | --- |
| Stage 1 `Source Intake` | `Partial` | Есть intake для `Lottie JSON` (Files/URL/Clipboard), нет полноценного intake для `SVG` и `Prompt/Spec`. |
| Stage 2 `Canonicalization` | `Missing` | Нет отдельной canonical model и шага нормализации. |
| Stage 3 `Draft Generation` | `Partial` | Draft по сути равен импортированному JSON; генерации из SVG/Prompt нет. |
| Stage 4 `Syntax Gate` | `Partial` | Есть базовая проверка обязательных полей (`v/w/h/layers`), нет schema-level gate и отчета. |
| Stage 5 `Motion Semantic Gate` | `Partial` | Есть ручная проверка через preview controls, нет formal semantic gate/report. |
| Stage 6 `Runtime Gate` | `Partial` | Есть runtime preview на одном клиенте, нет формализованного gate и pass/fail артефакта. |
| Stage 7 `Issue Resolution Loop` | `Partial` | Есть ручной цикл “правка -> повторная проверка”, нет bounded retries, QAReport и rollback policy. |
| Stage 8 `Release Candidate` | `Missing` | Нет сущности `ReadyCandidate` и gate aggregation. |
| Stage 9 `Publish/Handoff` | `Missing` | Нет `ReadyLottie`, release manifest, checksum, handoff flow. |

## Для планирования

1. Считать текущую app-логику `JSON-first local QA tool`.
2. В backlog выделять отдельный workstream на state machine + immutable revisions.
3. AI-track планировать как optional overlay, не как mandatory dependency.
