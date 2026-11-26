# A disposable Debian server for the headless Commander rehearsal: systemd
# with a user instance, OpenSSH, tmux and git. Node and Claude Code are left
# out so `agentctl host doctor` has something to report.
FROM debian:bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session libpam-systemd \
      openssh-server sudo ca-certificates curl tmux git \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash ops \
 && echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops \
 && install -d -o ops -g ops -m 0700 /home/ops/.ssh \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nAllowStreamLocalForwarding yes\n' > /etc/ssh/sshd_config.d/rehearsal.conf \
 && systemctl enable ssh \
 && systemctl mask getty.target console-getty.service systemd-firstboot.service
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
