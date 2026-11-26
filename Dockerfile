# Switchboard release image.
#
#   - builder: docker.io/hexpm/elixir (https://hub.docker.com/r/hexpm/elixir/tags)
#   - runner:  docker.io/debian (same Debian snapshot as the builder)
#
# Debian rather than Alpine avoids DNS and NIF compatibility surprises.
# OTP 28.5.0.9 or later: earlier OTP 28 releases have a TLS 1.2 client certificate-validation flaw.
ARG ELIXIR_VERSION=1.19.7
ARG OTP_VERSION=28.5.0.9
ARG DEBIAN_VERSION=trixie-20261123-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config first, so a change there recompiles the dependencies.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib

RUN mix compile

COPY assets assets
RUN mix assets.deploy

# runtime.exs changes don't need a recompile.
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates tini curl \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# An unprivileged user that owns nothing in the image: the release is read-only to it.
RUN useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin switchboard

WORKDIR "/app"

ENV MIX_ENV="prod"
ENV PORT="4000"
# The root filesystem is read-only at run time; the release writes its generated sys.config
# here (mount a tmpfs at /tmp).
ENV RELEASE_TMP="/tmp"

COPY --from=builder --chown=root:root /app/_build/${MIX_ENV}/rel/switchboard ./
COPY LICENSE /app/LICENSE

USER switchboard
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS http://localhost:4000/healthz || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

# Runs migrations, then starts the server (rel/overlays/bin/server).
CMD ["/app/bin/server"]
