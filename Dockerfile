FROM ubuntu:14.04
MAINTAINER Matt Jones <jonesmr@gmail.com>

RUN apt-get update && apt-get install -y \
    libffi6 \
    libmysqlclient-dev \
    libpcre3-dev

RUN mkdir -p /deploy/bin && mkdir -p /deploy/static
ADD .cabal-sandbox/bin/WorkoutsMain /deploy/WorkoutsMain
ADD static /deploy/static/

EXPOSE 8000

ENTRYPOINT ["/deploy/WorkoutsMain"]
