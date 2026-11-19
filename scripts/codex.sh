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

probe_bridge() {
    node -e '
        const { createHmac, randomBytes, timingSafeEqual } = require("crypto");
        const nonce = randomBytes(32).toString("hex");
        const expected = Buffer.from(createHmac("sha256", process.env.BRIDGE_TOKEN)
            .update(`codex-host-bridge-v1:${nonce}`).digest("hex"));
        // 0: bridge confirmado, 1: porta ocupada, 2: conexão recusada.
        const req = require("http").get(`http://127.0.0.1:3000/health/${nonce}`, res => {
            const proof = Buffer.from(res.headers["x-codex-bridge-proof"] || "");
            process.exit(res.statusCode === 204 && proof.length === expected.length &&
                timingSafeEqual(proof, expected) ? 0 : 1);
        });
        req.on("error", err => process.exit(err.code === "ECONNREFUSED" ? 2 : 1));
        setTimeout(() => process.exit(1), 1000);
    '
}

case "${1:-}" in
setup)
    [[ $(uname -s) == Linux ]] || fail 'Este fluxo requer Linux (--network host).'
    packages=()
    command -v docker >/dev/null || packages+=(docker.io)
    command -v node >/dev/null || packages+=(nodejs)
    if ((${#packages[@]})); then
        command -v apt-get >/dev/null || fail 'Instalação automática disponível para Debian/Ubuntu. Instale Docker e Node.js 12+ e tente novamente.'
        admin apt-get update
        admin apt-get install -y "${packages[@]}"
    fi
    node -e 'if (Number(process.versions.node.split(".")[0]) < 12) process.exit(1)' || fail 'Atualize o Node.js do host para a versão 12 ou superior.'
    docker_command
    if [[ ! -e .bridge-token ]]; then
        (umask 077; node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' > .bridge-token)
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
    [[ -n $BRIDGE_TOKEN ]] || fail 'O arquivo .bridge-token está vazio.'
    occupied='A porta 3000 está ocupada por um serviço que não foi identificado como o bridge deste projeto.'
    if probe_bridge; then
        printf 'Reutilizando o bridge na porta 3000.\n'
    else
        [[ $? == 2 ]] || fail "$occupied"
        node server.cjs &
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
            if probe_bridge; then
                ready=true
                break
            else
                [[ $? == 2 ]] || fail "$occupied"
            fi
            kill -0 "$bridge_pid" 2>/dev/null || fail 'O bridge não iniciou.'
        done
        [[ $ready == true ]] || fail 'O bridge não respondeu a tempo.'
    fi
    "${DOCKER[@]}" run -it --rm \
        --network host \
        -v "$PWD:/workspace" \
        -v codex-data:/root/.codex \
        -e BRIDGE_TOKEN="$BRIDGE_TOKEN" \
        --entrypoint /bin/bash \
        "$CODEX_IMAGE" /workspace/scripts/codex.sh launch --sandbox danger-full-access
    ;;
launch)
    codex_home=${CODEX_HOME:-"$HOME/.codex"}
    mkdir -p -- "$codex_home"
    instructions="$codex_home/AGENTS.md"
    if [[ -s "$codex_home/AGENTS.override.md" ]]; then
        instructions="$codex_home/AGENTS.override.md"
    fi
    readme_rule='Ao trabalhar neste projeto em /workspace, leia /workspace/README.md, ao lado do Makefile, no início da sessão. Consulte as instruções do bridge antes de executar comandos no host.'
    exec {instructions_fd}>>"$instructions"
    flock -x "$instructions_fd"
    if ! grep -Fxq -- "$readme_rule" "$instructions"; then
        printf '\n%s\n' "$readme_rule" >&"$instructions_fd"
    fi
    exec {instructions_fd}>&-
    shift
    exec codex "$@"
    ;;
*) fail 'Uso: bash scripts/codex.sh setup|run|launch' ;;
esac
