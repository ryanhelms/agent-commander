FROM scratch AS relay
COPY commander-relay /commander-relay
USER 65532:65532
ENTRYPOINT ["/commander-relay"]
CMD ["-config","/run/relay/edge.json"]

FROM golang:1.26-bookworm AS fixture
COPY fixture-server /fixture-server
USER 65532:65532
ENTRYPOINT ["/fixture-server"]
