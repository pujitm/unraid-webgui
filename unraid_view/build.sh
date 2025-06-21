# docker run --rm -it --platform linux/amd64 \
#   -e ERL_AFLAGS="+JMsingle true" \
#   -v $PWD:/app -w /app elixir:1.18.4 sh -lc "
#     apt update && apt-get update && apt-get install -y git build-essential libncurses-dev &&
#     apt install openssl=3.5.0 &&
#     export SECRET_KEY_BASE=GN8yDibBh48V7NzCNmwFr5cu3qeI7ee5z8lxH4ZeRJl30Zztn2DaZpfw/8SIQRAd &&
#     mix deps.get --only prod &&
#     MIX_ENV=prod mix compile &&
#     MIX_ENV=prod mix assets.deploy &&
#     mix phx.gen.release &&
#     MIX_ENV=prod mix release --overwrite
# "

docker run --rm -it --platform linux/amd64 \
  -e ERL_AFLAGS="+JMsingle true" \
  -v $PWD:/app -w /app elixir:1.18.4 sh -lc "
    # 1) Add Debian testing repo
    echo 'deb http://deb.debian.org/debian testing main' \
      > /etc/apt/sources.list.d/testing.list &&

    # 2) Pin priorities: 
    #    - all testing packages very low (90)…
    #    - but openssl* very high (990)
    printf 'Package: *\nPin: release a=testing\nPin-Priority: 90\n\n\
Package: openssl*\nPin: release a=testing\nPin-Priority: 990\n' \
      > /etc/apt/preferences.d/limit-testing &&

    # 3) Update & install
    apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      build-essential \
      libncurses-dev \
      openssl/testing && \
      libc6
    rm -rf /var/lib/apt/lists/* &&

    # 4) Continue with your mix workflow
    openssl version && \
    export SECRET_KEY_BASE=GN8yDibBh48V7NzCNmwFr5cu3qeI7ee5z8lxH4ZeRJl30Zztn2DaZpfw/8SIQRAd && \
    mix deps.get --only prod && \
    MIX_ENV=prod mix compile && \
    MIX_ENV=prod mix assets.deploy && \
    mix phx.gen.release && \
    MIX_ENV=prod mix release --overwrite
"