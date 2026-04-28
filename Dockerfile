FROM alpine:3

ENV LANG=C.UTF-8 \
    RCLONE_VER=1.72.1-r3 \
    REGULAR_USER=abc

ADD scripts/* /usr/local/sbin/
ADD files/*   /
COPY deps/builds/unrar-7.2.5-r0.apk  /tmp/unrar.apk

RUN apk update && \
    apk add --no-cache --allow-untrusted /tmp/unrar.apk && \
    apk add --no-cache \
        rclone=$RCLONE_VER \
        mkvtoolnix \
        ffmpeg \
        unzip \
        grep \
        file \
        coreutils \
        findutils \
        iputils \
        curl \
        bash \
        ca-certificates \
        shadow \
        tzdata \
        msmtp \
        logrotate && \
    useradd -u 1000 -U -G users -d /config -s /bin/false $REGULAR_USER && \
    chown -R root:root /usr/local/sbin/ && \
    chmod -R 755 /usr/local/sbin/ && \
    ln -s /usr/local/sbin/setup.sh /setup.sh && \
    ln -s /usr/local/sbin/sync.sh /sync.sh && \
    ln -s /usr/local/sbin/common.sh /common.sh && \
    rm -rf /var/cache/apk/* /tmp/* /root/.cache

#USER $REGULAR_USER  # continue as root, as we need to set UID & GID in entrypoint!
ENTRYPOINT ["/usr/local/sbin/entry.sh"]

