# A disposable Debian server with systemd and SSH, standing in for a remote
# host in the service rehearsal. PostgreSQL is deliberately not installed.
FROM debian:bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server sudo ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash ops \
 && echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops \
 && install -d -o ops -g ops -m 0700 /home/ops/.ssh \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/rehearsal.conf \
 && systemctl enable ssh \
 && systemctl mask getty.target console-getty.service systemd-firstboot.service
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
