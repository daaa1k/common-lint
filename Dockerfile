# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# Base image: digest updates via Renovate Dockerfile manager (docker datasource).
# ARG *_VERSION + *_SHA256: customManagers (regex) in renovate.json use datasource
# github-release-attachments (asset SHA256), not github-releases (tag commit digest).
# If your preset sets enabledManagers, include "custom.regex" (and "dockerfile") there.
FROM node:24-bookworm@sha256:5711a0d445a1af54af9589066c646df387d1831a608226f4cd694fc59e745059

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git jq \
  && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH

ARG ACTIONLINT_VERSION=v1.7.12
ARG GHALINT_VERSION=v1.5.6
ARG ZIZMOR_VERSION=v1.25.2
ARG TRIVY_VERSION=v0.70.0
ARG TYPOS_VERSION=v1.47.0

RUN set -eux; \
  case "$TARGETARCH" in \
    amd64) \
      AL_ARCH=amd64; \
      ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8; \
      GHALINT_SHA256=98ee0e3330de7286f470d1e89c03ff7ce70d7a5998ba0f15969c400447be579c; \
      ZIZMOR_SHA256=aa1facd105f0d83fe5c55b1adcd9d7417de5d83aa27471f91dc0b66cf3803577; \
      ZIZMOR_ASSET=zizmor-x86_64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9; \
      TYPOS_SHA256=6f8a935cea6c60b060082b862a7e777bfd92d939a4fd4194d8085b086dfe24e4; \
      TYPOS_ASSET=typos-${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz; \
      ;; \
    arm64) \
      AL_ARCH=arm64; \
      ACTIONLINT_SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6; \
      GHALINT_SHA256=203a22c70b40bb161626973ad2a8dd06aeb736699fc8e03dd425dee8ff3406e6; \
      ZIZMOR_SHA256=4b4b9491112c2a09b318101c0d3349b73af1c4f532e097dd6d0164f2abda760d; \
      ZIZMOR_ASSET=zizmor-aarch64-unknown-linux-gnu.tar.gz; \
      TRIVY_SHA256=2f6bb988b553a1bbac6bdd1ce890f5e412439564e17522b88a4541b4f364fc8d; \
      TYPOS_SHA256=0349ec65605216136b57c3ea6f1a02034e7e8bc128788474b635396997015d54; \
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
