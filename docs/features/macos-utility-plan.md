# macOS Utility Plan: AI-assisted Lottie pipeline

> Дата: 14 June 2026
> Документ-основание: `docs/features/llm-integration-plan.md`, `docs/core-pipeline.md`
> Статус: execution plan для переноса на macOS-таргет

## 0. Цель

macOS дев-утилита, упрощающая создание красивых 60fps 2D-анимаций:
- понятный API-контракт (`AnimationSpec`) для Claude/Codex;
- Lottie из существующего SVG или с нуля;
- ИИ генерирует только верхнеуровневый сценарий, детерминированный `LottieCompiler` собирает валидный bodymovin;
- **lottie-ios — ядро запуска и проверки** анимаций.

Снимаемое ограничение: на macOS можно вызывать уже залогиненные CLI (`claude`/`codex`) подпроцессом → используется подписка пользователя, без Messages API key.

## 1. Что переносится 1:1 (чистый Foundation, без правок)

- `Sources/AI/Spec/AnimationSpec.swift`
- `Sources/AI/Spec/AnimationSpecSchema.swift`
- `Sources/AI/Spec/LottieCompiler.swift`
- `Sources/Pipeline/**` (модели, gates, оркестрация, storage, resolution, release) — Foundation-only.
- `Sources/AI/Contracts`, `Adapter`, `Economics`, `Performance` — контракты остаются.
- `Sources/Models/**`, `Sources/Store/AnimationStore.swift`, `RevisionStore.swift` — Foundation/Observation, переносятся.

Проверка переносимости: они уже компилируются хостовым swiftc (см. `bin/check_lottie_compiler.sh`).

## 2. Что меняется / добавляется

### 2.1 Таргет
- В `project.yml` (xcodegen) добавить **macOS app target** (`platform: macOS`, `deploymentTarget: 13.0+`), переиспользующий Core-исходники.
- Разделить sources на:
  - **Core** (Spec, Pipeline, Models, Store) — общий для iOS/macOS;
  - **Platform UI** — `#if os(macOS)` / `os(iOS)`.
- `Package.swift` (Swift Playgrounds, iOS-only) остаётся для iOS; macOS-таргет живёт в xcodegen-проекте.

### 2.2 Провайдер: `CLIProviderAdapter` (формат проверен на машине)

Реализует существующий `AIProviderAdapter`. Вместо HTTP — `Foundation.Process`.

**Команда (проверено, `claude` 1.0.61):**
```
claude -p "<user request + layer list>" \
  --append-system-prompt "<AnimationSpec contract + motion rules + 'output ONLY AnimationSpec JSON'>" \
  --output-format json \
  --model opus \
  --disallowedTools "Bash Edit Write Read Glob Grep WebSearch WebFetch"   # one-shot, без agent loop
```

**Формат вывода (зафиксирован):**
```json
{"type":"result","subtype":"success","is_error":false,
 "result":"<строка = текст модели = наш AnimationSpec JSON>",
 "total_cost_usd":..., "usage":{...}, "session_id":"..."}
```
Парсинг: decode обёртки → проверить `is_error==false` → взять `.result` (String) → `JSONDecoder` в `AnimationSpec` → `LottieCompiler.compile` → draft → `AIResult(patchedJSONRef:)`.
Repair-loop N=2: при `is_error==true` или ошибке decode — повтор с текстом ошибки в промпте.

**Операционные требования (выявлены при проверке):**
1. **Чистое окружение.** Перед `exec` снять `ANTHROPIC_*` / `CLAUDE_*` env-vars (иначе наследуется чужой `ANTHROPIC_AUTH_TOKEN` → `401 Invalid bearer token`). В Finder-запущенном приложении их не будет, но снимать defensively обязательно.
2. **Резолв пути к `claude`.** GUI-приложение из Finder получает минимальный PATH (без nvm, где лежит `claude`). Решение: запускать через login-shell `/bin/zsh -lc 'claude …'`, либо один раз определить абсолютный путь (`zsh -lc 'command -v claude'`) и закэшировать, либо дать поле «путь к claude» в настройках.
3. **Накладные.** Дефолтный system-prompt Claude Code тяжёлый (~68k cache-creation токенов, ~3.6с на вызов). `--disallowedTools` срезает определения тулов и agent-loop. `--append-system-prompt` (в 1.0.61 нет `--system-prompt` для полной замены — только append).
4. **Биллинг.** `total_cost_usd` информативный; при логине через Max-подписку покрывается ею (поле показывает notional cost, не доп. списание) — подтвердить на стороне пользователя.

Флаги (проверены `claude --help`): `-p`, `--output-format json`, `--append-system-prompt`, `--model`, `--disallowedTools`, `--fallback-model`.

Провайдер-агностично: `CodexCLIProviderAdapter` по тому же контракту (другой бинарь/флаги; `codex` установлен).
Файлы: `Sources/AI/Adapter/CLIProviderAdapter.swift`, `Sources/AI/Adapter/CLIPrompts.swift`.

### 2.3 lottie-ios на macOS (runner)
- `LottieAnimationView` работает на macOS (NSView). Текущая обёртка `LottieView` — `UIViewRepresentable` под `#if canImport(UIKit)`.
- Добавить `#if os(macOS)` ветку через `NSViewRepresentable` (тот же playback API: loop/speed/range/progress sync).
- Файл: `Sources/Views/LottieAnimationNSView.swift` (или объединить в существующий с `#if`).

### 2.4 lottie-ios как validator (Runtime gate, 60fps)
Дорастить `Sources/Pipeline/Gates/RuntimeGate.swift`, чтобы реально гонять lottie-ios офскрин:
1. **Structural**: decode `LottieAnimation.from(data:)` (Codable) — провал = syntax finding.
2. **Frame-grid / 60fps**: проверить `fr==60` (или целевой), keyframe `t` целочисленны (выровнены по кадрам).
3. **Offscreen render sampling**: построить `LottieAnimationLayer`, выставлять `currentProgress` на сетке 1/60с, `forceDisplayUpdate()`, рендерить слой в `CGImage`, проверять непустые/неломаные кадры (не all-transparent на интервалах, где ожидается контент).
4. **CA-engine compatibility**: создать view с `LottieConfiguration(renderingEngine: .automatic)`, через колбэк `animationLayerDidLoad` прочитать резолвнутый `RenderingEngine`. Если `.mainThread` (fallback) — finding severity `medium`: «риск просадки 60fps, фича не поддержана CA-движком».
- Эти проверки → `QAFinding` в существующий `QAReport`; ничего в оркестраторе менять не надо.

### 2.5 Сборка / дистрибуция
- Дев-утилита распространяется как **notarized DMG (Developer ID)**, **вне App-Store-песочницы** — иначе `Process`-вызов `claude`/`codex` заблокирован sandbox.
- Подписать Developer ID, notarize, staple. Codemagic (`codemagic.yaml`) — расширить macOS-workflow.

## 3. Расширение примитивов компилятора (качество «красоты»)

Добавлять инкрементально, каждый с golden-тестом (DSL → ожидаемый Lottie фрагмент) через `bin/check_lottie_compiler.sh`:
- **stagger** — групповая анимация со сдвигом по слоям (delay per index) для каскадных появлений.
- **mask / matte** — анимация маски (track matte) для reveal-эффектов.
- **path morph** — keyframes на `sh.ks` (морфинг вершин) для трансформаций формы.
- **gradient animation** — keyframes на `gf`/`gs` стопах.
- **parenting** — учитывать `parent` слоёв при offset.
- **easing presets +** — расширить spring/bounce, добавить cubic-bezier пресеты (back, elastic) для «живого» движения.

Motion-design качество: добавить в `CLIPrompts` слой правил тайминга/choreography (адаптировать LottieFiles motion-design-skill) — ИИ выбирает вкусные тайминги, компилятор гарантирует валидность.

## 4. Фазировка

| Фаза | Содержание | Результат |
|------|-----------|-----------|
| **M1** | macOS-таргет в project.yml; перенос Core; `NSViewRepresentable` обёртка lottie-ios; сборка на macOS | Утилита открывает/превьюит Lottie на macOS |
| **M2** | RuntimeGate на lottie-ios (offscreen + CA-compat + frame-grid); прогон `~/Desktop/rocket_animated.json` | Реальные 60fps QA-gates через lottie-ios |
| **M3** | `CLIProviderAdapter` (`claude -p` + repair-loop) + вклинивание в Stage 3/7; SVG/prompt intake | End-to-end: запрос → сценарий → компиляция → проверка → превью |
| **M4** | Расширение примитивов (stagger/mask/morph/gradient) + motion-промпт | Богатые, «красивые» анимации |
| **M5** | Notarized DMG вне песочницы; codemagic macOS workflow | Распространяемая утилита |

## 5. Файлы

**Создать:**
- `Sources/AI/Adapter/CLIProviderAdapter.swift`, `CLIPrompts.swift`
- `Sources/Views/LottieAnimationNSView.swift` (или `#if os(macOS)` в существующем)
- `Sources/Views/macOS/**` (утилитный UI: импорт, превью, экспорт)
- golden-тесты примитивов (расширить `bin/`)

**Изменить:**
- `project.yml` (macOS target, split sources)
- `Sources/Pipeline/Gates/RuntimeGate.swift` (lottie-ios offscreen + engine-compat)
- `Sources/Pipeline/Storage/RevisionStore.swift` (Stage 3/7 → CLIProviderAdapter, как в llm-integration-plan)
- `Sources/Pipeline/Canonicalization/CanonicalizationService.swift` (`.promptSpec`)
- `codemagic.yaml` (macOS notarized workflow)

## 6. Что гарантируется vs зависит от итерации

**Гарантируется технически:**
- валидный bodymovin (компилятор + decode-gate);
- кадрово-выровненные 60fps тайминги;
- определение CA-движок vs main-thread fallback (риск fps) через lottie-ios;
- запуск/превью и офскрин-проверка через lottie-ios как единое ядро.

**Зависит от motion-дизайна и итерации (не one-shot):**
- эстетическое качество («красота») — easing-пресеты + motion-промпт + repair-loop;
- богатые эффекты — по мере расширения примитивов компилятора.

## 7. Риски

1. Формат вывода `claude -p` может отличаться — зафиксировать перед M3 (проверить на машине).
2. Sandbox блокирует Process — решается дистрибуцией вне App Store (notarized DMG).
3. Офскрин-рендер lottie-ios на CA-движке вне окна — возможно потребуется явный `LottieAnimationLayer` + ручной `forceDisplayUpdate()`; fallback на main-thread engine для детерминированного офскрина.
4. Качество «красоты» — митигировать motion-промптом и расширением примитивов поэтапно.
