ARG base
FROM $base
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends uidmap
RUN echo 'root:0:65536' | tee /etc/subuid /etc/subgid
ENTRYPOINT [ "unshare", "--map-root-user", "--map-users", "auto", "--map-groups", "auto", "--mount" ]
