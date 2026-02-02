FROM debian:13-slim AS builder

ARG PDNS_VERSION

# Install build dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		autoconf \
		automake \
		bison \
		bzip2 \
		ca-certificates \
		curl \
		default-libmysqlclient-dev \
		flex \
		g++ \
		gawk \
		libboost-all-dev \
		libcap2-bin \
		libcurl4-openssl-dev \
		libgeoip-dev \
		liblua5.3-dev \
		libluajit-5.1-dev \
		libmaxminddb-dev \
		libpq-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libtool \
		libyaml-cpp-dev \
		lua-yaml-dev \
		lua5.3 \
		luajit \
		make \
		pkg-config \
		python3-venv \
		ragel \
		vim \
		wget \
	&& apt-get clean

WORKDIR /src

# Download & extract
RUN wget https://downloads.powerdns.com/releases/pdns-${PDNS_VERSION}.tar.bz2 \
    && tar xf pdns-${PDNS_VERSION}.tar.bz2 --strip-components=1

# Build and install into /build dir
RUN ./configure \
		--prefix=/usr \
		--sysconfdir="/etc/pdns" \
		--localstatedir=/var \
		--libdir="/usr/lib/pdns" \
		--with-modules="" \
		--with-dynmodules="bind gmysql gpgsql gsqlite3" \
		--enable-tools \
		--disable-static \
		--with-libcrypto=/usr \
	&& make -j"$(nproc)" \
	&& DESTDIR=/build make install \
	&& strip /build/usr/bin/* /build/usr/lib/pdns/pdns/*.so /build/usr/sbin/*

# Give pdns_server capability to bind low ports (setcap writes xattr into binary)
RUN setcap 'cap_net_bind_service=+ep' /build/usr/sbin/pdns_server

# Prepare runtime tree
RUN mkdir -p /runtime \
	&& cp -a /build/* /runtime/

# Collect required shared libs and copy (ldd scanning)
RUN find /build -type f -executable -exec sh -c \
	'for f; do ldd "$f" 2>/dev/null | awk "/=>/ {print \$3}" ; done' sh {} + \
	| sort -u | grep -E "^/" | xargs -r -I{} cp --parents {} /runtime

# We also need vim and dependencies for "pdnsutil zone edit" in runtime
RUN cp -a /usr/bin/vim.basic /runtime/usr/bin/ \
	&& ldd /usr/bin/vim.basic | awk '/=>/ {print $3}' \
	| sort -u | grep -E "^/" | xargs -r -I{} cp --parents {} /runtime

# Convert to UsrMerge layout (Debian 13 requirement)
# Move /lib, /lib64, /bin, /sbin to /usr and create symlinks
RUN if [ -d /runtime/lib ]; then \
		cp -a /runtime/lib/* /runtime/usr/lib/ && rm -rf /runtime/lib && ln -s usr/lib /runtime/lib; \
	fi \
	&& if [ -d /runtime/lib64 ]; then \
		cp -a /runtime/lib64/* /runtime/usr/lib64/ && rm -rf /runtime/lib64 && ln -s usr/lib64 /runtime/lib64; \
	fi \
	&& if [ -d /runtime/bin ]; then \
		cp -a /runtime/bin/* /runtime/usr/bin/ && rm -rf /runtime/bin && ln -s usr/bin /runtime/bin; \
	fi \
	&& if [ -d /runtime/sbin ]; then \
		cp -a /runtime/sbin/* /runtime/usr/sbin/ && rm -rf /runtime/sbin && ln -s usr/sbin /runtime/sbin; \
	fi

# Create pdns user/group files
RUN mkdir -p /runtime/etc \
    && echo "pdns:x:1000:1000:PowerDNS user:/var/lib/pdns:/sbin/nologin" > /runtime/etc/passwd \
    && echo "pdns:x:1000:" > /runtime/etc/group

# Ensure runtime dirs exist and are owned by pdns
RUN mkdir -p \
		/runtime/data \
		/runtime/etc/pdns \
		/runtime/run/pdns \
		/runtime/var/run/pdns \
		/runtime/var/log/pdns \
		/runtime/var/lib/pdns \
    && chown -R 1000:1000 \
		/runtime/data \
		/runtime/etc/pdns \
		/runtime/run/pdns \
		/runtime/var/run/pdns \
		/runtime/var/log/pdns \
		/runtime/var/lib/pdns \
    && chmod 0755 /runtime/etc/pdns

# Cleanup /runtime of unnecessary files
RUN rm -rf \
		/runtime/usr/share/doc \
		/runtime/usr/share/man

FROM gcr.io/distroless/base-debian13:debug AS runtime

ARG PDNS_VERSION

LABEL maintainer="Joern Schonhoff <joern.schonhoff@outlook.de>"
LABEL description="PowerDNS Authoritative Server ${PDNS_VERSION} Debug based on Distroless Debian 13"
LABEL version="${PDNS_VERSION}"
LABEL license="MIT"
LABEL org.opencontainers.image.authors="Joern Schonhoff <joern.schonhoff@outlook.de>"
LABEL org.opencontainers.image.created="FILLED BY BUILD SYSTEM"
LABEL org.opencontainers.image.description="PowerDNS Authoritative Server ${PDNS_VERSION} Debug based on Distroless Debian 13"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.revision="FILLED BY BUILD SYSTEM"
LABEL org.opencontainers.image.source="https://gitlab.com/joern_schonhoff/pdns-auth-distroless"
LABEL org.opencontainers.image.title="pdns-auth-distroless-debug"
LABEL org.opencontainers.image.url="https://gitlab.com/joern_schonhoff/pdns-auth-distroless"
LABEL org.opencontainers.image.version="${PDNS_VERSION}"

# Copy runtime fs from builder
COPY --from=builder /runtime/ /

# Expose DNS ports
EXPOSE 53/tcp 53/udp

# Run as pdns user created in /etc/passwd (UID 1000)
USER 1000:1000

ENTRYPOINT [ "/busybox/sh" ]
CMD [ "-c", "while true; do sleep 100; done" ]
