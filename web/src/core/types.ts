// Общие типы ядра. Lottie держим как разобранный JSON-объект (как в Swift-версии — [String: Any]).
export type Lottie = Record<string, any>;

export interface CompileResult { lottie: Lottie; warnings: string[] }

export interface SVGImportResult { lottie: Lottie; layerNames: string[]; warnings: string[] }
