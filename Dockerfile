# syntax=docker/dockerfile:1

FROM hexpm/elixir:1.20.4-erlang-28.5.0.6-alpine-3.24.1 AS build

RUN apk add --no-cache build-base git

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib

RUN mix compile
RUN mix release

FROM alpine:3.24.1 AS runtime

RUN apk add --no-cache ca-certificates libstdc++ ncurses-libs openssl

WORKDIR /app
ENV HOME=/app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/mithril ./

USER nobody

CMD ["bin/mithril", "start"]
