# A tailnet client for the tailnet rehearsal: tailscaled, plus netcat to
# confirm the Docker host answers only over the tailnet. The rehearsal copies
# in Linux builds of commander-relay and the device agent.
FROM tailscale/tailscale:stable
RUN apk add --no-cache netcat-openbsd
