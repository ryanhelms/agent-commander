# One-container relay: commander-relay host mode with its embedded JetStream
# broker and a private PostgreSQL child. State lives in the /data volume.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/commander-relay ./cmd/commander-relay
COPY internal ./internal
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -mod=readonly -p 2 -trimpath -buildvcs=false \
    -o /out/commander-relay ./cmd/commander-relay && mkdir /out/data

FROM postgres:17-alpine
COPY --from=build /out/commander-relay /usr/local/bin/commander-relay
# PostgreSQL refuses to run as root. The image's postgres account owns /data,
# so a new named volume inherits that owner. COPY needs no emulated RUN step
# when building for another architecture.
COPY --from=build --chown=postgres:postgres --chmod=0700 /out/data /data
ENV COMMANDER_PG_BIN=/usr/local/bin LC_ALL=C.UTF-8
USER postgres
VOLUME /data
EXPOSE 8443
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/commander-relay", "host", "--dir", "/data"]
