FROM node:22-bookworm-slim

ARG OPENSHELL_VERSION=v0.0.116
ARG DOCKER_CLI_VERSION=27.5.1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    lsof \
    procps \
    python3 \
    socat \
    tar \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "${arch}" in \
    amd64) docker_arch=x86_64; musl_arch=x86_64 ;; \
    arm64) docker_arch=aarch64; musl_arch=aarch64 ;; \
    *) echo "unsupported architecture=${arch}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
    | tar -xz --strip-components=1 -C /usr/local/bin docker/docker; \
  chmod +x /usr/local/bin/docker; \
  curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/openshell-${musl_arch}-unknown-linux-musl.tar.gz" \
    | tar -xz -C /usr/local/bin; \
  chmod +x /usr/local/bin/openshell

ENV PATH="/usr/local/bin:/root/.local/bin:${PATH}" \
    NEMOCLAW_OPENSHELL_BIN=/usr/local/bin/openshell \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    GIT_TERMINAL_PROMPT=0

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /root
ENTRYPOINT ["/entrypoint.sh"]
