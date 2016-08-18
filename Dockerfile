FROM ubuntu:14.04

RUN apt-get update -y && \
    apt-get install -y postgresql-client && \
    apt-get clean -y

RUN apt-get install -y python-pip && \
    pip install awscli

ENTRYPOINT ["/usr/bin/psql"]
