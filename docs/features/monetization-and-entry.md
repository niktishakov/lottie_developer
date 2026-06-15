# Feature: Monetization and Entry Flows (Onboarding + Paywall)

## Purpose

Эта группа фич отвечает за первичный вход пользователя в приложение и ограничения free/pro доступа к импорту.

## Onboarding (as-is)

1. Показ онбординга контролируется `@AppStorage("hasCompletedOnboarding")`.
2. Структура: 5 экранов (`OnboardingPage`).
3. Есть staged reveal-анимации для части экранов.
4. Финальный CTA:
   - `Continue to Library`, если пользователь уже `Pro`;
   - `Unlock Pro`, если `Free`.
5. На финальном CTA для `Free` открывается paywall.

## Важная оговорка

Onboarding визуально рассказывает расширенный pipeline, включая AI/convert narrative. По `docs/core-pipeline.md` это демонстрационный слой, не архитектурный source of truth.

## Paywall + Purchase (as-is)

1. StoreKit продукты:
   - `com.nikapps.lottie.developer.pro.lifetime`
   - `com.nikapps.lottie.developer.pro.annual`
2. Загрузка продуктов с retry (`1s`, `2s`, `4s` backoff).
3. Поддержка:
   - purchase;
   - restore purchases (`AppStore.sync`);
   - transaction listener (`Transaction.updates`).
4. `isPro` определяется наличием entitlements.

## Gating rules (as-is)

1. Все импорты из библиотеки закрыты за `Pro`.
2. Preview и работа с уже существующими локальными файлами остаются доступны.
3. Paywall может открываться:
   - из библиотеки;
   - из onboarding финального CTA.

## Локализация (фактическое состояние)

1. `en` содержит полный набор onboarding ключей.
2. В `ru` отсутствует значительная часть новых onboarding ключей (AI/convert/version sections).
3. Риск: mixed/fallback строки на RU-локали в новых онбординг-сценах.

## Связь с release readiness

1. Монетизация импорта уже работает для v1 BYO-free-core модели.
2. Для соответствия `core-pipeline.md` остается добавить AI-экономику и guardrails:
   - BYO key integration layer;
   - hard/soft quotas;
   - degraded mode policy;
   - SLA/SLO мониторинг AI-операций.
