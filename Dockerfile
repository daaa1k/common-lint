# syntax=docker/dockerfile:1
# Base image: digest updates via Renovate Dockerfile manager (docker datasource).
# ARG *_VERSION: updates via customManagers (regex) in renovate.json (not legacy regexManagers).
# If your preset sets enabledManagers, include "custom.regex" (and "dockerfile") there.
FROM node:24-bookworm@sha256:bb20cf73b3ad7212834ec48e2174cdcb5775f6550510a5336b842ae32741ce6c

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git jq \
  && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH

ARG ACTIONLINT_VERSION=v1.7.12
ARG GHALINT_VERSION=v1.5.5
ARG ZIZMOR_VERSION=v1.24.1
ARG TRIVY_VERSION=v0.69.3

RUN set -eux; \
  case "$TARGETARCH" in \
    amd64) \
      AL_ARCH=amd64; \
      ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8; \
      GHALINT_SHA256=579cbf9024f86a8255ce8acdd56c7792f0f9a7e76063d64cfb7b66ff65c396e4; \
      ZIZMOR_SHA256=67a8df0a14352dd81882e14876653d097b99b0f4f6b6fe798edc0320cff27aff; \
      ZIZMOR_ASSET=zizmor-x86_64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=1816b632dfe529869c740c0913e36bd1629cb7688bd5634f4a858c1d57c88b75; \
      ;; \
    arm64) \
      AL_ARCH=arm64; \
      ACTIONLINT_SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6; \
      GHALINT_SHA256=c3ab464130015d733bfc75a2851f4fc5b3cb966aca2ed8bc0fa2a029bc0ee6af; \
      ZIZMOR_SHA256=3725d7cd7102e4d70827186389f7d5930b6878232930d0a3eb058d7e5b47e658; \
      ZIZMOR_ASSET=zizmor-aarch64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=7e3924a974e912e57b4a99f65ece7931f8079584dae12eb7845024f97087bdfd; \
      ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  AL_VER="${ACTIONLINT_VERSION#v}"; \
  GH_VER="${GHALINT_VERSION#v}"; \
  TRIVY_VER="${TRIVY_VERSION#v}"; \
  case "$TARGETARCH" in \
    amd64) TRIVY_ASSET="trivy_${TRIVY_VER}_Linux-64bit.tar.gz" ;; \
    arm64) TRIVY_ASSET="trivy_${TRIVY_VER}_Linux-ARM64.tar.gz" ;; \
  esac; \
  curl -fsSL "https://github.com/rhysd/actionlint/releases/download/${ACTIONLINT_VERSION}/actionlint_${AL_VER}_linux_${AL_ARCH}.tar.gz" -o /tmp/actionlint.tgz; \
  echo "${ACTIONLINT_SHA256}  /tmp/actionlint.tgz" | sha256sum -c -; \
  tar -xzf /tmp/actionlint.tgz -C /usr/local/bin actionlint; \
  rm -f /tmp/actionlint.tgz; \
  curl -fsSL "https://github.com/suzuki-shunsuke/ghalint/releases/download/${GHALINT_VERSION}/ghalint_${GH_VER}_linux_${AL_ARCH}.tar.gz" -o /tmp/ghalint.tgz; \
  echo "${GHALINT_SHA256}  /tmp/ghalint.tgz" | sha256sum -c -; \
  tar -xzf /tmp/ghalint.tgz -C /usr/local/bin ghalint; \
  rm -f /tmp/ghalint.tgz; \
  curl -fsSL "https://github.com/zizmorcore/zizmor/releases/download/${ZIZMOR_VERSION}/${ZIZMOR_ASSET}" -o /tmp/zizmor.tgz; \
  echo "${ZIZMOR_SHA256}  /tmp/zizmor.tgz" | sha256sum -c -; \
  tar -xzf /tmp/zizmor.tgz -C /usr/local/bin ./zizmor; \
  rm -f /tmp/zizmor.tgz; \
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/${TRIVY_ASSET}" -o /tmp/trivy.tgz; \
  echo "${TRIVY_SHA256}  /tmp/trivy.tgz" | sha256sum -c -; \
  tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy; \
  rm -f /tmp/trivy.tgz

COPY npm-deps/package.json npm-deps/package-lock.json /opt/npm-deps/
WORKDIR /opt/npm-deps
RUN npm ci --omit=dev \
  && npm cache clean --force

COPY merge-commitlint-config.mjs /opt/npm-deps/

ENV PATH="/opt/npm-deps/node_modules/.bin:/usr/local/bin:${PATH}"
ENV NODE_PATH="/opt/npm-deps/node_modules"

COPY commitlint.config.cjs /opt/common-lint/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /github/workspace
ENTRYPOINT ["/entrypoint.sh"]
