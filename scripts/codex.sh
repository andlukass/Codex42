#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
CODEX_IMAGE=${CODEX_IMAGE:-my-codex}

fail() { printf '%s\n' "$*" >&2; exit 1; }
admin() {
    if [[ $(id -u) == 0 ]]; then "$@"; else
        command -v sudo >/dev/null || fail 'É necessário sudo para instalar/iniciar o Docker.'
        sudo "$@"
    fi
}

docker_command() {
    DOCKER=(docker)
    if ! docker info >/dev/null 2>&1; then
        if ! admin docker info >/dev/null 2>&1; then
            if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
                admin systemctl start docker
            elif command -v service >/dev/null; then
                admin service docker start
            else
                fail 'Inicie o daemon Docker no host e execute make novamente.'
            fi
        fi
        if ! docker info >/dev/null 2>&1; then DOCKER=(sudo docker); fi
    fi
    "${DOCKER[@]}" info >/dev/null || fail 'Não foi possível acessar o Docker.'
}

case "${1:-}" in
setup)
    [[ $(uname -s) == Linux ]] || fail 'Este fluxo requer Linux (--network host).'
    packages=()
    command -v docker >/dev/null || packages+=(docker.io)
    command -v node >/dev/null || packages+=(nodejs)
    if ((${#packages[@]})); then
        command -v apt-get >/dev/null || fail 'Instalação automática disponível para Debian/Ubuntu. Instale Docker e Node.js 18+ e tente novamente.'
        admin apt-get update
        admin apt-get install -y "${packages[@]}"
    fi
    node -e 'if (Number(process.versions.node.split(".")[0]) < 18) process.exit(1)' || fail 'Atualize o Node.js do host para a versão 18 ou superior.'
    docker_command
    if [[ ! -e .bridge-token ]]; then
        (umask 077; node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))' > .bridge-token)
    fi
    [[ -s .bridge-token ]] || fail 'O arquivo .bridge-token está vazio; configure um token antes de continuar.'
    chmod 600 .bridge-token
    "${DOCKER[@]}" build -t "$CODEX_IMAGE" .
    printf '\nAmbiente pronto. Execute: make codex\n'
    ;;
run)
    docker_command
    export BRIDGE_TOKEN
    BRIDGE_TOKEN=$(cat .bridge-token)
    node server.mjs &
    bridge_pid=$!
    cleanup() {
        kill "$bridge_pid" 2>/dev/null || true
        wait "$bridge_pid" 2>/dev/null || true
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ready=false
    for ((attempt=0; attempt<50; attempt++)); do
        sleep 0.1
        kill -0 "$bridge_pid" 2>/dev/null || fail 'O bridge não iniciou. Confira se a porta 3000 já está ocupada.'
        if node -e '
            fetch("http://127.0.0.1:3000/exec", {
                method: "POST",
                headers: {"Content-Type": "application/json", Authorization: `Bearer ${process.env.BRIDGE_TOKEN}`},
                body: JSON.stringify({command: process.execPath, args: ["-e", "process.exit(0)"]}),
                signal: AbortSignal.timeout(1000)
            }).then(async r => { if (!r.ok || (await r.json()).exitCode !== 0) process.exit(1); })
              .catch(() => process.exit(1));
        ' 2>/dev/null; then ready=true; break; fi
    done
    [[ $ready == true ]] || fail 'O bridge não respondeu a tempo.'
    "${DOCKER[@]}" run -it --rm \
        --network host \
        -v "$PWD:/workspace" \
        -v codex-data:/root/.codex \
        -e BRIDGE_TOKEN="$BRIDGE_TOKEN" \
        "$CODEX_IMAGE" --sandbox danger-full-access
    ;;
*) fail 'Uso: bash scripts/codex.sh setup|run' ;;
esac
