FROM perl:latest

RUN apt-get update \
  && apt-get install -y postgresql-client

WORKDIR /usr/local/registry

RUN cpanm https://github.com:Tamarou/registry.git

# TODO:  figure out the command to run the app
CMD ["prove", "t"]
