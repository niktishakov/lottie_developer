import Foundation

/// Компактный промежуточный DSL, который выдаёт LLM (structured output).
///
/// LLM никогда не пишет Lottie JSON напрямую. Он описывает анимацию поверх уже существующих,
/// именованных слоёв статичного Lottie, а детерминированный `LottieCompiler` превращает spec
/// в валидные keyframes. Это гарантирует синтаксическую валидность по построению.
struct AnimationSpec: Codable, Equatable {
    /// Кадров в секунду композиции. Компилятор клампит в диапазон 24…60.
    let fps: Int
    /// Длительность композиции в кадрах (op). ip всегда 0. Компилятор клампит 1…600.
    let durationFrames: Int
    /// Анимации, сгруппированные по целевым слоям.
    let layers: [LayerAnimationSpec]

    static let minFPS = 24
    static let maxFPS = 60
    static let maxDurationFrames = 600
}

/// Набор анимаций для одного слоя статичного Lottie.
struct LayerAnimationSpec: Codable, Equatable {
    /// Имя слоя (`nm`) в статичном Lottie — ключ матчинга. Если слой не найден, компилятор
    /// добавляет warning и пропускает спек (без падения).
    let target: String
    let animations: [MotionPrimitive]
}

/// Один high-level примитив движения с таймингом и easing.
struct MotionPrimitive: Codable, Equatable {
    let kind: MotionKind
    /// Старт в секундах от начала композиции.
    let start: Double
    /// Конец в секундах.
    let end: Double
    let easing: Easing
    /// Параметры, зависящие от `kind`. Все опциональны; компилятор подставляет дефолты.
    let params: MotionParams?

    init(kind: MotionKind, start: Double, end: Double, easing: Easing = .easeInOut, params: MotionParams? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.easing = easing
        self.params = params
    }
}

enum MotionKind: String, Codable, CaseIterable {
    case fadeIn
    case fadeOut
    case slideIn
    case slideOut
    case scaleIn
    case scaleOut
    case rotate
    case pulse
    case bounce
    case drawOn
    case wiggle
    // M4 — idle/accent loops для «живого» движения:
    case spin     // непрерывный поворот на 360°×repeatCount
    case float    // мягкое вертикальное покачивание (hover)
    case breathe  // тонкое масштабное «дыхание»
    case swing    // маятниковое колебание поворота
}

enum Easing: String, Codable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring
    // M4 — overshoot / anticipation (Lottie допускает y вне [0,1] у хэндлов):
    case easeOutBack    // лёгкий перелёт в конце
    case easeInBack     // оттяжка в начале
    case easeInOutBack
    case anticipate     // короткая оттяжка, затем движение
}

/// Объединённый набор параметров для всех примитивов. Каждый `kind` читает только релевантные поля.
struct MotionParams: Codable, Equatable {
    /// "up" | "down" | "left" | "right" — направление движения (slideIn/slideOut).
    var direction: String?
    /// Дистанция в пикселях (slideIn/slideOut).
    var distance: Double?
    /// Начальное значение в процентах (scaleIn/scaleOut).
    var from: Double?
    /// Конечное значение в процентах (scaleIn/scaleOut).
    var to: Double?
    /// Начальный угол в градусах (rotate).
    var fromDeg: Double?
    /// Конечный угол в градусах (rotate).
    var toDeg: Double?
    /// Магнитуда (pulse: пиковый %, bounce: смещение px, wiggle: амплитуда px).
    var amount: Double?
    /// Частота (wiggle: число колебаний за интервал).
    var frequency: Double?
    /// Число повторов (pulse).
    var repeatCount: Int?

    init(
        direction: String? = nil,
        distance: Double? = nil,
        from: Double? = nil,
        to: Double? = nil,
        fromDeg: Double? = nil,
        toDeg: Double? = nil,
        amount: Double? = nil,
        frequency: Double? = nil,
        repeatCount: Int? = nil
    ) {
        self.direction = direction
        self.distance = distance
        self.from = from
        self.to = to
        self.fromDeg = fromDeg
        self.toDeg = toDeg
        self.amount = amount
        self.frequency = frequency
        self.repeatCount = repeatCount
    }
}
