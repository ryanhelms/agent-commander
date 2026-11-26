# A disposable Docker Engine host with SSH, standing in for a remote host in
# the container rehearsal. The SSH user runs Docker without sudo.
FROM docker:29-dind
RUN apk add --no-cache openssh-server \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh ops \
 && addgroup ops docker \
 && echo 'ops:*' | chpasswd -e \
 && install -d -o ops -g ops -m 0700 /home/ops/.ssh \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> /etc/ssh/sshd_config \
 && printf '#!/bin/sh\n/usr/sbin/sshd\nexec dockerd-entrypoint.sh "$@"\n' > /usr/local/bin/testhost \
 && chmod 0755 /usr/local/bin/testhost
ENV DOCKER_TLS_CERTDIR=
ENTRYPOINT ["/usr/local/bin/testhost"]
