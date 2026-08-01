ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus \
    curl gnupg lsb-release ca-certificates \
    iproute2 iputils-ping \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Standard "systemd in docker" trim — disable units irrelevant/broken in a container
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp* \
    2>/dev/null || true

STOPSIGNAL SIGRTMIN+3

VOLUME ["/sys/fs/cgroup"]

CMD ["/sbin/init"]
