FROM docker.io/alpine/git:v2.47.2

COPY git-sync.sh /git-sync/

RUN chmod +x /git-sync/git-sync.sh

WORKDIR /

ENTRYPOINT ["/git-sync/git-sync.sh"]