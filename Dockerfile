FROM node:22-bookworm-slim

# Instalar dependências
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       procps \
       git \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Priorizar IPv4 sobre IPv6
RUN printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf

# Instalar Codex CLI
RUN npm install -g @openai/codex

WORKDIR /workspace

ENTRYPOINT ["codex"]