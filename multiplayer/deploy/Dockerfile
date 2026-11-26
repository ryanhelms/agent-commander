FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY hostkit ./hostkit
RUN go mod download
COPY cmd/commander-relay ./cmd/commander-relay
COPY internal ./internal
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -mod=readonly -p 2 -trimpath -o /out/commander-relay ./cmd/commander-relay

FROM scratch
COPY --from=build /out/commander-relay /commander-relay
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENTRYPOINT ["/commander-relay"]
CMD ["-config", "/run/relay/edge.json"]
