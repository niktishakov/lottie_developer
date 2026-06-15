# Implementation Plan: Core Pipeline Gap Closure

Дата: 23 February 2026  
Документ-основание: `docs/core-pipeline.md`  
Текущий baseline: `docs/features/README.md`, `docs/features/release-gaps-vs-core-pipeline.md`

## 1. Goal

Привести приложение от текущего `JSON-first local QA tool` к production-модели из `core-pipeline.md`:

1. `Artifact State Machine` с 9 стадиями.
2. Deterministic quality gates (`Syntax`, `Motion Semantic`, `Runtime`).
3. Immutable revisions + rollback.
4. `ReadyCandidate` и `ReadyLottie`.
5. Optional AI branch (`assistive + bounded`) без блокировки offline release path.

## 2. Planning Principles

1. Offline-first путь не должен ломаться на любом этапе внедрения.
2. AI остается optional enhancement, не mandatory dependency.
3. Каждая новая стадия пайплайна вводится с наблюдаемым UI-состоянием.
4. Сначала deterministic core, потом multi-source, потом AI.
5. BYO key only для v1 AI-функций.

## 3. Release Milestones

## M1: Deterministic Core Beta

1. Работают стадии 1/3/4/5/6/7/8/9 для `Lottie JSON`.
2. Есть ревизии, gate results, rollback и release candidate.
3. Offline release path полностью операбелен без AI.

## M2: Multi-Source Beta

1. Добавлен intake для `SVG` и `Prompt/Spec`.
2. Реализован `Canonicalization` (Stage 2).
3. Все входы сводятся к `DraftArtifact`.

## M3: AI Assist Beta

1. AI task types `generate/analyze/patch` в Stage 3 и Stage 7.
2. AI outputs всегда проходят Stage 4 -> 5 -> 6.
3. Включены BYO key, quotas, alerts, degraded mode.

## 4. Epic Backlog (Execution-Ready)

## Epic 0: Pipeline Domain Foundation

Priority: `P0`  
Covers stages: cross-cutting (all)

### Outcome

В проекте появляются canonical типы артефактов и единый pipeline-домен, не привязанный к текущему `AnimationItem`.

### Scope

1. Ввести спецификационные типы:
   - `SourceArtifact`
   - `DraftArtifact`
   - `QAReport`
   - `ReadyCandidate`
   - `ReadyLottie`
   - `PipelineStage`, `StageResult`, `GateResult`
   - `ArtifactRevision`
2. Добавить mapping между legacy `AnimationItem` и новой моделью.
3. Добавить storage layout для revisions и manifests.

### Target files

1. Create: `Sources/Pipeline/Models/PipelineModels.swift`
2. Create: `Sources/Pipeline/Models/PipelineEnums.swift`
3. Create: `Sources/Pipeline/Storage/RevisionStore.swift`
4. Modify: `Sources/Store/AnimationStore.swift`

### DoD

1. В коде есть все canonical типы из `core-pipeline`.
2. Legacy imports создают начальную revision.
3. Данные загружаются после рестарта без потери lineage.

## Epic 1: State Machine Orchestrator

Priority: `P0`  
Covers stages: `1..9`

### Outcome

Появляется оркестратор переходов между стадиями с явными entry/exit rules.

### Scope

1. Реализовать `PipelineOrchestrator` с transition rules.
2. Реализовать `retryable/fail/degraded/pass` статусы стадий.
3. Добавить rollback pointer в state transitions.
4. Добавить API для запуска stage run и stage re-run.

### Target files

1. Create: `Sources/Pipeline/Orchestration/PipelineOrchestrator.swift`
2. Create: `Sources/Pipeline/Orchestration/PipelineTransitionRules.swift`
3. Create: `Sources/Pipeline/Orchestration/PipelineRunContext.swift`

### UI deliverables

1. Новый `PipelineStatusView` с текущей стадией и историей переходов.
2. Stage timeline на экране превью/QA.

### Target UI files

1. Create: `Sources/Views/Pipeline/PipelineStatusView.swift`
2. Modify: `Sources/Views/AnimationPlayerView.swift`

### DoD

1. Возможен управляемый переход по стадиям и возврат в Stage 7.
2. Логика переходов совпадает с диаграммой из `core-pipeline.md`.
3. Stage state виден в UI.

## Epic 2: Quality Gates (Deterministic)

Priority: `P0`  
Covers stages: `4`, `5`, `6`

### Outcome

Quality gates реализованы как отдельные deterministic проверки с машиночитаемыми результатами.

### Scope

1. `Syntax Gate`:
   - parse integrity;
   - required fields;
   - schema checks.
2. `Motion Semantic Gate`:
   - timing consistency;
   - range coherence;
   - loop semantics;
   - basic visual intent heuristics.
3. `Runtime Gate`:
   - playback at speed presets;
   - reopen/replay stability checks;
   - import/export roundtrip sanity.
4. Формирование `QAReport` и severity aggregation.

### Target files

1. Create: `Sources/Pipeline/Gates/SyntaxGate.swift`
2. Create: `Sources/Pipeline/Gates/MotionSemanticGate.swift`
3. Create: `Sources/Pipeline/Gates/RuntimeGate.swift`
4. Create: `Sources/Pipeline/Gates/QAReportBuilder.swift`

### UI deliverables

1. `GateResultsCard` (pass/fail/degraded/retryable).
2. `QAReportView` со списком findings и severity.

### Target UI files

1. Create: `Sources/Views/Pipeline/GateResultsCard.swift`
2. Create: `Sources/Views/Pipeline/QAReportView.swift`
3. Modify: `Sources/Views/AnimationPlayerView.swift`

### DoD

1. После gate-run сохраняется `GateResult` + `QAReport`.
2. Gate failures переводят процесс в Stage 7.
3. Gate statuses отображаются в UI и доступны для логики release candidate.

## Epic 3: Issue Resolution Loop + Rollback

Priority: `P0`  
Covers stages: `7`

### Outcome

Issue loop становится управляемым: bounded retries, rollback, manual resolution path.

### Scope

1. Retry budget для conversion/gate-retry операций.
2. Rollback к последней валидной ревизии.
3. Manual mark-as-resolved с обязательным re-gating.
4. Хранение diff summary между ревизиями.

### Target files

1. Create: `Sources/Pipeline/Resolution/IssueResolutionService.swift`
2. Create: `Sources/Pipeline/Resolution/RollbackService.swift`
3. Create: `Sources/Pipeline/Resolution/RevisionDiffService.swift`

### UI deliverables

1. `IssueResolutionPanel`:
   - retry count;
   - rollback button;
   - re-run gates action.
2. `RevisionHistoryView` с selectable rollback point.

### Target UI files

1. Create: `Sources/Views/Pipeline/IssueResolutionPanel.swift`
2. Create: `Sources/Views/Pipeline/RevisionHistoryView.swift`
3. Modify: `Sources/Views/AnimationPlayerView.swift`

### DoD

1. Retry budget исчерпывается предсказуемо и блокирует бесконечные циклы.
2. Rollback возвращает рабочую ревизию без потери lineage.
3. Пользователь может продолжить manual path после rollback.

## Epic 4: Release Candidate + Publish/Handoff

Priority: `P0`  
Covers stages: `8`, `9`

### Outcome

Появляется формальный финальный этап: `ReadyCandidate` -> `ReadyLottie`.

### Scope

1. `ReadyCandidate` entity:
   - revision_id;
   - gate_results snapshot;
   - risk_flags.
2. `Publish/Handoff`:
   - `release_manifest`;
   - `checksum`;
   - exported `ReadyLottie`.
3. Проверка handoff consistency до завершения stage 9.

### Target files

1. Create: `Sources/Pipeline/Release/ReleaseCandidateService.swift`
2. Create: `Sources/Pipeline/Release/PublishHandoffService.swift`
3. Create: `Sources/Pipeline/Release/ChecksumService.swift`

### UI deliverables

1. `ReleaseCandidateView` с gate summary и risk flags.
2. `PublishSheet` с export/share final artifact.

### Target UI files

1. Create: `Sources/Views/Pipeline/ReleaseCandidateView.swift`
2. Create: `Sources/Views/Pipeline/PublishSheet.swift`
3. Modify: `Sources/Views/AnimationPlayerView.swift`

### DoD

1. Пользователь может утвердить candidate только после pass всех 3 gates.
2. На publish создается `ReadyLottie` + manifest + checksum.
3. Артефакт экспортируется в предсказуемом формате.

## Epic 5: Multi-Source Intake + Canonicalization

Priority: `P1`  
Covers stages: `1`, `2`, `3`

### Outcome

Pipeline принимает не только JSON, но и `SVG`, `Prompt/Spec`.

### Scope

1. Ввести source selector:
   - `SVG`;
   - `Lottie JSON`;
   - `Prompt/Spec`.
2. Реализовать canonicalization service.
3. Обновить draft generation, чтобы любые входы приводились к `DraftArtifact`.

### Target files

1. Create: `Sources/Pipeline/Intake/SourceIntakeService.swift`
2. Create: `Sources/Pipeline/Canonicalization/CanonicalizationService.swift`
3. Create: `Sources/Pipeline/Draft/DraftGenerationService.swift`
4. Modify: `Sources/Views/AnimationLibraryView.swift`

### UI deliverables

1. `ImportSourcePickerView` с типами источников.
2. `PromptSpecInputView` (structured form).
3. `CanonicalizationResultView` для ошибок/предупреждений.

### Target UI files

1. Create: `Sources/Views/Import/ImportSourcePickerView.swift`
2. Create: `Sources/Views/Import/PromptSpecInputView.swift`
3. Create: `Sources/Views/Import/CanonicalizationResultView.swift`

### DoD

1. Для всех 3 source types создается валидный `DraftArtifact` или явная ошибка.
2. Ошибки canonicalization не приводят к потере состояния.
3. Stage 2 становится реальным этапом, а не описанием.

## Epic 6: Optional AI Branch (Assistive + Bounded)

Priority: `P1-P2`  
Covers stages: `3`, `7`

### Outcome

AI-интеграция работает как optional acceleration layer с fallback в deterministic path.

### Scope

1. Provider-agnostic contracts:
   - `AIRequest`;
   - `AIResult`;
   - `AIError`;
   - `AICapabilities`.
2. AI task types:
   - `generate`;
   - `analyze`;
   - `patch`.
3. Ограничение входа AI в Stage 3 и Stage 7.
4. Автоматический re-gating AI outputs через Stage 4-6.
5. Fallback на deterministic/manual при AI-error.

### Target files

1. Create: `Sources/AI/Contracts/AIContracts.swift`
2. Create: `Sources/AI/Adapter/AIProviderAdapter.swift`
3. Create: `Sources/AI/Adapter/AIProviderRegistry.swift`
4. Create: `Sources/Pipeline/AI/AIStageBridge.swift`

### UI deliverables

1. `AIActionPanel` внутри Stage 3/7.
2. `AIResultReviewView` (summary/findings/confidence/warnings/cost).
3. Явный banner “AI optional, deterministic path available”.

### Target UI files

1. Create: `Sources/Views/AI/AIActionPanel.swift`
2. Create: `Sources/Views/AI/AIResultReviewView.swift`
3. Modify: `Sources/Views/AnimationPlayerView.swift`

### DoD

1. AI step можно пропустить без блокировки pipeline.
2. Любой AI output проходит deterministic gates.
3. AI errors корректно маршрутизируются в fallback path.

## Epic 7: Economic Safety + SLO + Degraded Mode

Priority: `P1-P2`  
Covers: AI operations governance

### Outcome

Экономика AI управляется безопасно для indie-модели.

### Scope

1. BYO key settings flow.
2. Hard quotas:
   - per-user;
   - global cap.
3. Soft alerts на 50/80/95.
4. Forced stop AI-path при cap breach.
5. SLO tracking (`P95 <= 12s`) и degraded mode behavior.

### Target files

1. Create: `Sources/AI/Economics/AIQuotaManager.swift`
2. Create: `Sources/AI/Economics/AICostTracker.swift`
3. Create: `Sources/AI/Performance/AISLOTracker.swift`
4. Create: `Sources/AI/Performance/AIDegradedModePolicy.swift`

### UI deliverables

1. `AIUsageView` (quota/cost progress).
2. Alerts на порогах и баннер degraded mode.
3. `AISettingsView` для BYO key и policy.

### Target UI files

1. Create: `Sources/Views/AI/AIUsageView.swift`
2. Create: `Sources/Views/AI/AISettingsView.swift`
3. Modify: `Sources/Views/Paywall/PaywallView.swift` (copy alignment)

### DoD

1. Quota и cap политика enforce-ится.
2. При cap breach AI отключается, offline path продолжает работать.
3. SLO метрика и degraded mode видимы в UI.

## Epic 8: UX Alignment + Localization + Docs

Priority: `P2`

### Outcome

UX, onboarding и docs не конфликтуют с реальной архитектурой и готовы к релизной коммуникации.

### Scope

1. Обновить onboarding copy: явно “concept/demo” там, где фича не deterministic core.
2. Выравнять локализации:
   - закрыть missing RU keys;
   - исключить fallback-строки в критических флоу.
3. Обновить docs/features после реализации wave’ов.

### Target files

1. Modify: `Sources/Resources/ru.lproj/Localizable.strings`
2. Modify: `Sources/Resources/en.lproj/Localizable.strings`
3. Modify: `Sources/Views/Onboarding/OnboardingPageView.swift`
4. Modify: `docs/features/*.md`

### DoD

1. Нет missing localization keys между `en` и `ru`.
2. Onboarding не вводит в заблуждение относительно production state.
3. Docs синхронизированы с фактической реализацией.

## 5. Suggested Sprint Sequencing

## Sprint 1

1. Epic 0 (domain foundation)
2. Epic 1 (state machine skeleton + status UI)

## Sprint 2

1. Epic 2 (`Syntax` + `Motion` gates + QAReport UI)

## Sprint 3

1. Epic 2 (`Runtime` gate finalization)
2. Epic 3 (issue loop + rollback)

## Sprint 4

1. Epic 4 (release candidate + publish/handoff)
2. Epic 8 (localization baseline fixes)

## Sprint 5

1. Epic 5 (multi-source intake + canonicalization)

## Sprint 6

1. Epic 6 (optional AI branch)
2. Epic 7 (economics, SLO, degraded mode)

## 6. Implementation Dependencies

1. Epic 0 обязателен перед Epic 1-7.
2. Epic 1 обязателен перед Epic 2-4.
3. Epic 2 обязателен перед Epic 4.
4. Epic 6 зависит от Epic 3 и частично Epic 5.
5. Epic 7 зависит от Epic 6.

## 7. Verification Gates per Milestone

## Gate for M1

1. Все deterministic gates работают на JSON path.
2. Есть rollback и release candidate flow.
3. `ReadyLottie` генерируется с checksum.

## Gate for M2

1. SVG и Prompt/Spec проходят Stage 1-3.
2. Canonicalization ошибки корректно обрабатываются.
3. Мulti-source path не ломает existing JSON flow.

## Gate for M3

1. AI не обязателен для релиза.
2. AI outputs всегда проходят Stage 4-6.
3. Quotas/SLO/degraded mode работают и видимы пользователю.

## 8. Risks and Mitigations

1. Риск: чрезмерная сложность оркестратора.  
   Митигировать: начать с минимального path для JSON и расширять поэтапно.
2. Риск: регрессии текущего preview UX.  
   Митигировать: сохранить `AnimationPlayerView` как baseline, добавляя pipeline UI инкрементально.
3. Риск: неопределенный объем Motion Semantic Gate.  
   Митигировать: ввести v1 эвристики + явные severity levels, расширять позже.
4. Риск: cost drift при AI.  
   Митигировать: BYO key only + hard caps before public rollout.

## 9. Plan Completion Criteria

План считается выполненным, когда:

1. реализованы все `P0` эпики и пройден M1;
2. multi-source path доведен до M2;
3. AI-ветка включена как optional bounded enhancement (M3);
4. `docs/features` и `docs/core-pipeline.md` не противоречат фактической реализации.
