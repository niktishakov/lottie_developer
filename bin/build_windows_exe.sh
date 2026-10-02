#!/bin/zsh
# lottie-developer.exe для дизайнера на Windows x64 (MCP + просмотрщик в одном файле). Собирается на Mac через Bun.
set -e
ROOT="${0:A:h:h}"
cd "$ROOT/web"
bun install --frozen-lockfile >/dev/null
bun test
mkdir -p dist
bun build src/server/main.ts --compile --minify --target=bun-windows-x64 --outfile dist/lottie-developer.exe
cp "$ROOT/docs/DESIGNER_SETUP_WINDOWS.md" "dist/Как начать.md"
(cd dist && rm -f LottieDeveloper-windows.zip && zip -q LottieDeveloper-windows.zip lottie-developer.exe "Как начать.md")
ls -lh dist
