FROM golang:1.26-bookworm AS runtime
# This cached base supplies /usr/bin/git. The named context contains a static
# Linux test executable built by the rehearsal launcher.
COPY --from=binaries /pilot-peer /usr/local/bin/pilot-peer
COPY --from=binaries /agentctl /usr/local/bin/agentctl
RUN install -d -o 65532 -g 65532 -m 0700 /participant
ENV HOME=/participant
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/pilot-peer"]
CMD ["serve"]
