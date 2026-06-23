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
    /// Слои, которые компилятор создаёт перед анимацией (волны, ореолы, частицы).
    let generatedLayers: [GeneratedLayer]?

    static let minFPS = 24
    static let maxFPS = 60
    static let maxDurationFrames = 600

    init(fps: Int, durationFrames: Int, generatedLayers: [GeneratedLayer]? = nil, layers: [LayerAnimationSpec]) {
        self.fps = fps
        self.durationFrames = durationFrames
        self.layers = layers
        self.generatedLayers = generatedLayers
    }
}

/// Набор анимаций для одного слоя статичного Lottie.
struct LayerAnimationSpec: Codable, Equatable {
    /// Имя слоя (`nm`) в статичном Lottie — ключ матчинга. Поддерживает wildcard `*`
    /// в конце (`item_*`) — матчит все слои с данным префиксом.
    let target: String
    let animations: [MotionPrimitive]
    /// Задержка (сек) между каждым совпавшим слоем при wildcard-матчинге.
    /// Первый слой без задержки, второй +staggerDelay, третий +2×staggerDelay и т.д.
    let staggerDelay: Double?

    init(target: String, animations: [MotionPrimitive], staggerDelay: Double? = nil) {
        self.target = target
        self.animations = animations
        self.staggerDelay = staggerDelay
    }
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
    case swing      // маятниковое колебание поворота
    case followPath // движение вдоль bezier-пути (params.path)
    case recolor    // смена цвета fill/stroke (params.color)
    // M5 — расширенные примитивы:
    case squash          // X растёт, Y сжимается — удар/приземление
    case stretch         // Y растёт, X сжимается — растяжение
    case flash           // пульс прозрачности 100→min→100
    case flip            // 3D-поворот по оси Y или X (params.axis)
    case colorTransition // плавная смена цвета fill/stroke во времени
    case blurIn          // размытие → чёткость (появление)
    case blurOut         // чёткость → размытие (исчезновение)
    // M6 — shape-edit примитивы (мгновенные, start/end игнорируются):
    case removeFill      // удалить все fill из слоя
    case removeStroke    // удалить все stroke из слоя
    case addStroke       // добавить stroke (params.color, params.strokeWidth)
    case addFill         // добавить fill (params.color)
    case hideLayer       // скрыть слой (opacity=0 статически)
    case showLayer       // показать скрытый слой (opacity=100)
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
    // M5 — дополнительные кривые:
    case elastic        // сильная пружина с выраженным перелётом
}

/// Форма генерируемого слоя.
enum GeneratedShape: String, Codable, CaseIterable {
    case ellipse
    case rectangle
}

/// Описание слоя, который компилятор создаёт перед применением анимаций.
/// Позиционируется по центру существующего слоя-якоря (`anchor`).
struct GeneratedLayer: Codable, Equatable {
    /// Уникальное имя для таргетинга в `layers[].target`.
    let name: String
    /// Тип фигуры.
    let shape: GeneratedShape
    /// Имя существующего слоя, от которого берётся позиция.
    let anchor: String
    /// Ширина фигуры (px). По умолчанию 100.
    let width: Double?
    /// Высота фигуры (px). По умолчанию 100.
    let height: Double?
    /// Hex-цвет заливки. nil = без заливки (только обводка).
    let fillColor: String?
    /// Hex-цвет обводки. nil = без обводки.
    let strokeColor: String?
    /// Толщина обводки (px). По умолчанию 2.
    let strokeWidth: Double?
    /// Начальная прозрачность 0–100. По умолчанию 0 (невидим — анимируется через fadeIn).
    let opacity: Double?

    init(name: String, shape: GeneratedShape, anchor: String,
         width: Double? = nil, height: Double? = nil,
         fillColor: String? = nil, strokeColor: String? = nil,
         strokeWidth: Double? = nil, opacity: Double? = nil) {
        self.name = name
        self.shape = shape
        self.anchor = anchor
        self.width = width
        self.height = height
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.opacity = opacity
    }
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
    /// Контрольные точки пути (followPath): [[x,y], [x,y], ...]. Минимум 2 точки.
    var path: [[Double]]?
    /// Hex-цвет (recolor, colorTransition target): "#RRGGBB" или "#RGB".
    var color: String?
    /// Начальный hex-цвет (colorTransition source). Если nil — берётся текущий цвет fill/stroke.
    var fromColor: String?
    /// Радиус размытия (blurIn/blurOut, default 20).
    var blurAmount: Double?
    /// Ось поворота для flip: "x" или "y" (default "y").
    var axis: String?
    /// Толщина обводки для addStroke (default 2).
    var strokeWidth: Double?

    init(
        direction: String? = nil,
        distance: Double? = nil,
        from: Double? = nil,
        to: Double? = nil,
        fromDeg: Double? = nil,
        toDeg: Double? = nil,
        amount: Double? = nil,
        frequency: Double? = nil,
        repeatCount: Int? = nil,
        path: [[Double]]? = nil,
        color: String? = nil,
        fromColor: String? = nil,
        blurAmount: Double? = nil,
        axis: String? = nil,
        strokeWidth: Double? = nil
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
        self.path = path
        self.color = color
        self.fromColor = fromColor
        self.blurAmount = blurAmount
        self.axis = axis
        self.strokeWidth = strokeWidth
    }
}
