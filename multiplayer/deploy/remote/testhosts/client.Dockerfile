# A tailnet client for the tailnet rehearsal: tailscaled plus what the
# connection check and the Linux device agent need.
FROM tailscale/tailscale:stable
RUN apk add --no-cache python3 openssl
