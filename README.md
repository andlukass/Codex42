# Codex no Docker com acesso à máquina host

O Codex roda no container `my-codex`. Para executar comandos na máquina host, ele envia pedidos HTTP a um bridge Node.js que roda fora do container, com as permissões do usuário que o iniciou.

## Início rápido

Instale o projeto no seu diretório `sgoinfre`, em `/sgoinfre/$USER/containers`. No terminal da máquina **host**, execute:

```bash
cd "/sgoinfre/$USER/containers"
make
make codex
```

`make` instala Docker e Node.js quando necessário (Debian/Ubuntu com `apt-get`), inicia o serviço Docker, cria `.bridge-token` caso ainda não exista e constrói a imagem `my-codex`. É necessário ter `make` instalado; no Debian/Ubuntu: `sudo apt-get install -y make`. O bridge no host é compatível com Node.js 12 ou superior; o container do Codex usa Node.js 22. O host precisa de Node.js 12 ou superior e acesso à internet para baixar os pacotes e construir a imagem.

`make codex` verifica a preparação e abre o Codex no terminal atual. Se já houver um bridge na porta 3000 com o mesmo token, ele é reutilizado. Quando a porta está livre, o comando inicia um bridge e o encerra ao sair. Se a porta estiver ocupada por um serviço cuja identidade não puder ser confirmada, o comando retorna um erro. Se você estiver com um bridge de uma versão anterior em execução, reinicie-o para habilitar essa verificação. O primeiro acesso ao Codex pode solicitar login; a autenticação e os dados ficam no volume `codex-data`.

Se o usuário não puder acessar o Docker diretamente, os comandos Docker usam `sudo`. O bridge continua com as permissões do usuário que executou `make codex`; execute o Makefile como seu usuário normal. Sem `sudo` ou acesso a um Docker já instalado, será necessária a intervenção do administrador.

As próximas seções documentam o funcionamento e a execução manual; elas não são necessárias para o início rápido acima.

## 1. Preparar e iniciar o bridge no host

Entre neste diretório no terminal da máquina host:

```bash
cd "/sgoinfre/$USER/containers"
```

O arquivo do servidor se chama **server.cjs**. É necessário ter Node.js no host e Docker disponível para iniciar o container.

Na primeira configuração, gere um token aleatório. Este comando substitui qualquer token anterior; use apenas para configurar ou trocar o token:

```bash
umask 077
node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' > .bridge-token
chmod 600 .bridge-token
```

Carregue o token e inicie o servidor:

```bash
export BRIDGE_TOKEN="$(cat .bridge-token)"
node server.cjs
```

Mantenha esse terminal aberto. O servidor escuta em `127.0.0.1:3000`. Para parar, pressione Ctrl+C.

O token é uma senha para executar comandos no host: não o inclua em commits, README ou mensagens públicas. O mesmo valor precisa estar no ambiente do servidor e no container. Ao trocar o token, reinicie o bridge e o container com o novo valor.

## 2. Iniciar o Codex

Em outro terminal do host, carregue o mesmo token e execute:

```bash
cd "/sgoinfre/$USER/containers"
export BRIDGE_TOKEN="$(cat .bridge-token)"

docker run -it --rm \
  --network host \
  -v "$PWD:/workspace" \
  -v codex-data:/root/.codex \
  -e BRIDGE_TOKEN="$BRIDGE_TOKEN" \
  my-codex --sandbox danger-full-access
```

- `--network host`: no Linux desta máquina, permite acessar o bridge pelo endereço `127.0.0.1:3000` de dentro do container.
- `-v "$PWD:/workspace"`: disponibiliza o diretório atual do host em `/workspace`.
- `-v codex-data:/root/.codex`: persiste os dados do Codex entre execuções.
- `-e BRIDGE_TOKEN=...`: passa o token ao container.
- `--sandbox danger-full-access`: desativa o sandbox do Codex; não concede root no host.
- `--rm`: remove o container ao sair; o volume nomeado permanece.

Comandos executados normalmente pelo Codex continuam rodando dentro do container. Para agir no host, o Codex precisa chamar explicitamente o bridge. Você pode pedir: “Use o bridge em http://127.0.0.1:3000/exec com o BRIDGE_TOKEN do ambiente para executar comandos no host”.

## 3. Fazer uma chamada ao host

Dentro do container, este exemplo lista as portas seriais do host:

```bash
node -e '
fetch("http://127.0.0.1:3000/exec", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${process.env.BRIDGE_TOKEN}`
  },
  body: JSON.stringify({
    command: "ls",
    args: ["-l", "/dev/serial/by-id/"]
  }),
  signal: AbortSignal.timeout(15000)
})
.then(async res => {
  console.log("HTTP:", res.status);
  console.log("Resposta:", await res.json());
})
.catch(console.error);
'
```

Para testar identidade ou diretório, use `{ command: "whoami" }` ou `{ command: "pwd" }`.

**Separe o executável dos argumentos.** Use `{ command: "ls", args: ["-l", "/dev"] }`. Enviar `{ command: "ls -l /dev" }` falha porque o servidor usa `execFile`, sem shell. Expansões como `*`, variáveis, pipes e redirecionamentos não são interpretadas automaticamente.

## 4. Como funciona server.cjs

O servidor:

1. Lê `BRIDGE_TOKEN` do ambiente e exige que esteja definido.
2. Responde a `GET /health/<nonce>` com uma prova HMAC para que o cliente confirme a identidade do bridge sem transmitir o token. A execução de comandos usa `POST /exec`.
3. Verifica o cabeçalho `Authorization: Bearer <token>` com `timingSafeEqual`, após conferir o tamanho.
4. Recebe JSON com `command` (string) e `args` (lista de strings, opcional).
5. Executa o programa no host usando `execFile(command, args)`.
6. Retorna JSON com `stdout`, `stderr` e `exitCode`.

O processo filho herda o ambiente e o diretório de trabalho do bridge. Por isso, `pwd` retorna o diretório em que você iniciou `node server.cjs`.

Limites atuais: corpo de requisição de até 4096 caracteres, execução de até 10 segundos e buffer de saída de 1 MiB. Falhas de inicialização do comando ou timeout também podem aparecer como `exitCode: 1`.

HTTP 200 significa que o pedido foi processado: confira também `exitCode` e `stderr` para saber se o comando funcionou.

## 5. Permissões e diagnóstico

O bridge não exige root e não aumenta as permissões do usuário do host. Qualquer cliente que tenha o token e alcance o servidor pode executar programas com essas permissões. Mantenha o bind em localhost e proteja o token.

- `401 Unauthorized`: token ausente ou diferente; confira o ambiente dos dois processos.
- `ECONNREFUSED`: bridge parado ou endereço/rede incorretos.
- `exitCode: 1` com saída vazia: confira o nome do executável e se os argumentos foram enviados em `args`.
- `Permission denied`: o usuário do host não tem acesso ao recurso.

Na verificação feita nesta máquina, o Arduino Micro apareceu em `/dev/ttyACM0`, com link em `/dev/serial/by-id/`. A porta pertencia a `root:dialout`, sem ACL adicional, e o usuário não tinha permissão para abri-la. O bridge permite detectar a placa, mas não contorna essa restrição; um administrador precisa conceder acesso para comunicar com ela.

# Codex42
