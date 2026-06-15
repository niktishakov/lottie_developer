# Release Gaps vs `docs/core-pipeline.md`

## Контекст

Текущая app в продакшн-терминах: `JSON-first local QA tool` с pro-gated import, runtime preview и локальным persistence.

Target-модель из `docs/core-pipeline.md`: `Artifact State Machine` (9 стадий), immutable revisions, deterministic gates и optional bounded AI branch.

## Что уже можно считать готовым

1. Рабочий offline-first путь для локального JSON импорта и ручного QA.
2. Базовая валидация JSON на входе.
3. Runtime preview с ключевыми контролами (progress/range/speed/loop).
4. Локальное хранение без серверной зависимости.
5. Коммерческое ограничение импорта (`Pro`) и purchase flow.

## Критичные gaps (P0)

1. Нет `Artifact State Machine` и stage orchestration.
2. Нет immutable `ArtifactRevision` и lineage/rollback pointers.
3. Нет formal deterministic gates:
   - `Syntax Gate` как отдельного gate-result;
   - `Motion Semantic Gate` как формального чекпоинта;
   - `Runtime Gate` с явным pass/fail контрактом.
4. Нет `ReadyCandidate` и `ReadyLottie` сущностей.
5. Нет release manifest/checksum/handoff стадии.

## Важные gaps (P1)

1. Multi-source intake отсутствует:
   - `SVG` как source;
   - `Prompt/Spec` как source.
2. Нет `Canonicalization` шага.
3. Нет разделения `SourceArtifact` и `DraftArtifact`.
4. Нет структурированного `QAReport` (findings + severity).
5. Нет bounded retries policy и explicit fallback/rollback workflow.

## AI-specific gaps (P1-P2)

1. Нет provider-agnostic interface:
   - `AIRequest`, `AIResult`, `AIError`, `AICapabilities`.
2. Нет bounded AI integration в Stage 3/Stage 7.
3. Нет deterministic re-gating AI output через Stage 4-6.
4. Нет economics guardrails:
   - BYO key flow (runtime integration);
   - hard quotas + global cap;
   - soft alerts `50/80/95`;
   - forced AI stop policy.
5. Нет SLO instrumentation для AI (`P95 <= 12s`) и degraded mode.

## Supporting gaps (P2)

1. Неполная `ru` локализация новых onboarding ключей.
2. Нет telemetry для pipeline стадий и gate outcomes.
3. Нет экспортируемого audit trail по ревизиям и решениям gate.

## Рекомендуемая декомпозиция работ

## Wave 1: Deterministic Core (без AI)

1. Ввести state machine с 9 стадиями (минимально используемые переходы).
2. Ввести immutable revisions и rollback pointer.
3. Формализовать 3 quality gates и `QAReport`.
4. Добавить `Release Candidate` + `Publish/Handoff` артефакты.

## Wave 2: Multi-Source Expansion

1. Добавить `SourceArtifact` и canonical intake для `SVG` и `Prompt/Spec`.
2. Реализовать `Canonicalization`.
3. Добавить Draft generation path из новых source types.

## Wave 3: Optional AI Branch

1. Поднять provider-agnostic adapter contract.
2. Добавить `generate/analyze/patch` только в Stage 3/7.
3. Включить cost/SLO guardrails и degraded mode.
4. Зафиксировать BYO key only для v1 AI.

## Done-критерий “готово к release согласно core-pipeline”

1. Любой путь до публикации проходит через `Syntax -> Motion Semantic -> Runtime` gates.
2. Любой артефакт имеет revision lineage и rollback anchor.
3. AI path опционален и не блокирует offline release.
4. Release результат формализован как `ReadyLottie` с manifest/checksum.
