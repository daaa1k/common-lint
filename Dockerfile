# syntax=docker/dockerfile:1@sha256:2780b5c3bab67f1f76c781860de469442999ed1a0d7992a5efdf2cffc0e3d769
# Base image: digest updates via Renovate Dockerfile manager (docker datasource).
# ARG *_VERSION + *_SHA256: customManagers (regex) in renovate.json use datasource
# github-release-attachments (asset SHA256), not github-releases (tag commit digest).
# If your preset sets enabledManagers, include "custom.regex" (and "dockerfile") there.
FROM node:24-bookworm@sha256:33cf7f057918860b043c307751ef621d74ac96f875b79b6724dcebf2dfd0db6d

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git jq \
  && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH

ARG ACTIONLINT_VERSION=v1.7.12
ARG GHALINT_VERSION=v1.5.5
ARG ZIZMOR_VERSION=v1.24.1
ARG TRIVY_VERSION=v0.69.3
ARG TYPOS_VERSION=v1.45.1

RUN set -eux; \
  case "$TARGETARCH" in \
    amd64) \
      AL_ARCH=amd64; \
      ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8; \
      GHALINT_SHA256=579cbf9024f86a8255ce8acdd56c7792f0f9a7e76063d64cfb7b66ff65c396e4; \
      ZIZMOR_SHA256=a8000f3c683319a523d3b20df0e75457ba591f049cfcbfa98966631b56733c03; \
      ZIZMOR_ASSET=zizmor-x86_64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=1816b632dfe529869c740c0913e36bd1629cb7688bd5634f4a858c1d57c88b75; \
      TYPOS_SHA256=33447531a0eff29796d6fb9b555b4628723db72c6bad129e168d97ac86ceb0f1; \
      TYPOS_ASSET=typos-${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz; \
      ;; \
    arm64) \
      AL_ARCH=arm64; \
      ACTIONLINT_SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6; \
      GHALINT_SHA256=c3ab464130015d733bfc75a2851f4fc5b3cb966aca2ed8bc0fa2a029bc0ee6af; \
      ZIZMOR_SHA256=d66e37ef8a375fb07939c630ebf9709a6e0f20242bdc3faf672a7ed97e0b768d; \
      ZIZMOR_ASSET=zizmor-aarch64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=7e3924a974e912e57b4a99f65ece7931f8079584dae12eb7845024f97087bdfd; \
      TYPOS_SHA256=0d3688c607a49ffb6dedaca6de44e4217abeaa5b93228d673dc5caf76f60489f; \
      TYPOS_ASSET=typos-${TYPOS_VERSION}-aarch64-unknown-linux-musl.tar.gz; \
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
  tar -xzf /tmp/zizmor.tgz -C /usr/local/bin zizmor; \
  rm -f /tmp/zizmor.tgz; \
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/${TRIVY_ASSET}" -o /tmp/trivy.tgz; \
  echo "${TRIVY_SHA256}  /tmp/trivy.tgz" | sha256sum -c -; \
  tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy; \
  rm -f /tmp/trivy.tgz; \
  curl -fsSL "https://github.com/crate-ci/typos/releases/download/${TYPOS_VERSION}/${TYPOS_ASSET}" -o /tmp/typos.tgz; \
  echo "${TYPOS_SHA256}  /tmp/typos.tgz" | sha256sum -c -; \
  tar -xzf /tmp/typos.tgz -C /usr/local/bin ./typos; \
  rm -f /tmp/typos.tgz

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
