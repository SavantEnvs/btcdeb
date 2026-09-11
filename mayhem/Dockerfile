# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for btcdeb — builds on top of the org C/C++ base image
# (ghcr.io/mayhemheroes/base), which already ships clang/llvm + libFuzzer + autotools
# (autoconf/automake/libtool/pkg-config) and the build-contract ENV. btcdeb vendors secp256k1
# in-tree, so no extra apt packages and no network are needed — the build is air-gapped.
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run btcdeb's own Catch2 functional suite at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
