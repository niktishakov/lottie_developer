# LLM Integration Plan: DSL → Compiler → Anthropic Adapter

> Дата: 14 June 2026
> Документ-основание: `docs/core-pipeline.md`, `docs/features/implementation-plan.md` (Epic 6/7)
> Статус: execution plan для AI-ветки (M3)

## 0. Архитектурный принцип

LLM **никогда не пишет Lottie JSON напрямую**. Поток:

```
Источник (SVG / chat)
  → [детерминированно] статичная геометрия в Lottie-слои с именами (nm)
  → LLM выдаёт AnimationSpec (компактный DSL, structured output по JSON-схеме)
  → [детерминированно] LottieCompiler впрыскивает keyframes в слои по имени
  → существующие Stage 4→6 gates валидируют (LottieAnimation decode + render)
  → fail → Stage 7 → LLM patch (правит DSL, не JSON) → re-gating
```

Валидность Lottie гарантируется конструктивно: AI трогает только тайминги / easing / каналы
трансформации, геометрия остаётся той, что собрал детерминированный код.

Обоснование (research 2024–2026): zero-shot генерация сырого Lottie ≈ 0% валидных, few-shot 10–51%.
Надёжно только дообученные модели. Промежуточный DSL + детерминированный компилятор — путь, которым
идут LottieFiles Motion Copilot и Jitter AI.

## 1. AnimationSpec (DSL)

Компактный per-layer спек. Два уровня: high-level intents (основной) + raw keyframes (escape hatch,
позже). AI почти всегда использует intents.

Поля: `fps` (24…60), `durationFrames` (1…600), `layers[]`.
Каждый layer: `target` (имя слоя nm — ключ матчинга), `animations[]`.
Каждый primitive: `kind`, `start` (сек), `end` (сек), `easing`, `params`.

`kind`: fadeIn, fadeOut, slideIn, slideOut, scaleIn, scaleOut, rotate, pulse, bounce, drawOn, wiggle.
`easing`: linear, easeIn, easeOut, easeInOut, spring.
`params`: direction, distance, from, to, fromDeg, toDeg, amount, frequency, repeatCount (все опциональны).

Файлы: `Sources/AI/Spec/AnimationSpec.swift`, `Sources/AI/Spec/AnimationSpecSchema.swift`.

## 2. LottieCompiler

Чистый детерминированный Foundation-код (без сети, без UIKit). Вход: статичный Lottie JSON (Data) +
AnimationSpec. Выход: анимированный Lottie JSON (Data) + warnings.

Алгоритм:
1. Распарсить layers[], индекс по nm.
2. Для каждого target найти слой (нет → warning).
3. Каждый primitive → keyframes на канале transform `ks` (o/p/s/r) или trim `tm`.
4. easing → bezier-хэндлы i/o на keyframe (CSS cubic-bezier пресеты; spring/bounce → overshoot keyframes).
5. Секунды → кадры (`t = round(start * fps)`) — убирает класс ошибок тайминга Motion Semantic Gate.
6. Выставить ip:0, op:durationFrames, fr:fps.

Файл: `Sources/AI/Spec/LottieCompiler.swift`. Тест: `Tests/LottieCompilerTests.swift` (+ standalone
swiftc-проверка на хосте, т.к. iOS-таргет требует симулятора).

## 3. AnthropicProviderAdapter

Реализует существующий `AIProviderAdapter`. Вызов `POST /v1/messages` через URLSession, tool use со
схемой (`emit_animation_spec`, `tool_choice` forced). Декод `tool_use.input` → AnimationSpec → compile →
запись draft JSON → `AIResult(patchedJSONRef:)`. Замер latency → AISLOTracker, cost → AICostTracker,
consume → AIQuotaManager. Repair-loop до N=2 (compile → decode-чек → повтор с текстом ошибки).

Файлы: `Sources/AI/Adapter/AnthropicProviderAdapter.swift`, `Sources/AI/Adapter/AnthropicPrompts.swift`.

## 4. BYO-ключ

`Sources/AI/AIKeychain.swift` (Keychain, kSecClassGenericPassword). На старте приложения: ключ есть →
`AIProviderRegistry.shared.register(provider: AnthropicProviderAdapter(...))`, иначе Null остаётся.

## 5. Вклинивание в пайплайн (минимальные правки RevisionStore)

- Stage 3 `runDraftGeneration`: ветка AI generate (для `.promptSpec` или по запросу). На любой AIError →
  fallback в текущий детерминированный путь (offline-first сохраняется).
- Stage 7 `runIssueResolution`: ветка AI patch с findings → новый draft → авто re-gating Stage 4→6.
- Снять `throw .unsupportedSourceType` для `.promptSpec` в CanonicalizationService (минимальная канонизация).
- Gates не трогаем — `effectiveDraftURL` подхватит AI-draft автоматически.

## 6. Repair-loop / надёжность

В адаптере до N=2 попыток: compile → попытка decode `LottieAnimation` (Codable) как structural-чек →
при ошибке повторный запрос с текстом ошибки → исчерпали → AIError.invalidOutput → fallback.

## 7. UI (Epic 6/7)

- `Sources/Views/AI/AIActionPanel.swift` — кнопки «Generate with AI» (Stage 3) / «Fix with AI» (Stage 7),
  баннер degraded mode (`AIDegradedModePolicy.shared.bannerMessage`).
- `Sources/Views/AI/AISettingsView.swift` — BYO ключ, выбор модели, usage.
- Встроить в `PipelineRunView.stageContext` и `IssueResolutionPanel`.

## 8. Фазировка

| Фаза | Содержание | Результат |
|------|-----------|-----------|
| A | AnimationSpec + LottieCompiler + тесты (без сети) | Детерминированная сборка анимаций из DSL |
| B | AnthropicProviderAdapter + Keychain + регистрация + промпты | generate из chat поверх SVG end-to-end |
| C | Вклинивание в Stage 3/7 + fallback + repair-loop | AI как bounded accelerator внутри пайплайна |
| D | UI-панели + usage/degraded + `.promptSpec` канонизация | Chat-to-animation целиком, BYO ключ, квоты |

## 9. Файлы

Создать: `Sources/AI/Spec/AnimationSpec.swift`, `AnimationSpecSchema.swift`, `LottieCompiler.swift`,
`Sources/AI/Adapter/AnthropicProviderAdapter.swift`, `AnthropicPrompts.swift`, `Sources/AI/AIKeychain.swift`,
`Sources/Views/AI/AIActionPanel.swift`, `AISettingsView.swift`, `Tests/LottieCompilerTests.swift`.

Изменить: `Sources/Pipeline/Storage/RevisionStore.swift` (Stage 3/7),
`Sources/Pipeline/Canonicalization/CanonicalizationService.swift` (`.promptSpec`),
`Sources/Views/Pipeline/PipelineRunView.swift` + `IssueResolutionPanel.swift`,
`Sources/LottieDeveloperApp.swift` (регистрация провайдера).

## 10. Риски

1. Качество компилятора — митигировать ранними unit-тестами + golden-файлами.
2. Матчинг слоёв по имени — SVG-конвертер должен сохранять осмысленные nm из SVG id/<g>.
3. Chat без SVG — v1: «chat анимирует уже импортированный SVG». Полноценный text→vector отложить.
4. App Store / сеть — BYO ключ снимает биллинг-риски; offline-путь не ломается при отсутствии ключа.
