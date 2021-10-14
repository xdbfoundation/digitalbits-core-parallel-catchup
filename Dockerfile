FROM ubuntu:20.04
RUN apt-get update && apt-get install curl -y && curl -1sLf \
  'https://dl.cloudsmith.io/public/xdb-foundation/digitalbits-core/setup.deb.sh' \
  | bash && apt-get install digitalbits-core libpq-dev -y && rm -rf /var/lib/apt/lists/* 