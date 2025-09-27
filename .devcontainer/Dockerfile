# Update the VARIANT arg in docker-compose.yml to pick an Elixir version: 1.9, 1.10, 1.10.4
ARG VARIANT="1.18.4-otp-28"
FROM elixir:${VARIANT}

ARG PACKAGES="build-essential inotify-tools python3 postgresql-client curl xdg-utils qpdf watchman chromium-driver chromium fonts-noto-color-emoji fonts-noto-cjk"

RUN apt-get update \
    && apt-get install -y $PACKAGES \
    && fc-cache -f -v \
    && apt-get autoremove -y \
    && apt-get clean -y
