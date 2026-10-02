// Файлы, которые Bun встраивает в исполняемый файл (`with { type: "file" | "text" }`).
declare module "*.wasm" { const path: string; export default path; }
declare module "lottie-web/build/player/lottie.min.js" { const source: string; export default source; }
declare module "*.html" { const source: string; export default source; }
declare module "*/qrcode-generator/dist/qrcode.js" { const source: string; export default source; }
