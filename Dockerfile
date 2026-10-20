ARG DEBIAN_BASE_IMAGE=debian:13.7-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
ARG DISTROLESS_IMAGE=gcr.io/distroless/base-debian13@sha256:f2df8702d4dcc45ce76df6cbc14ad1975fcf88a04bd0e8947b6194264f9ab75e
ARG DNS_HEALTHCHECK_IMAGE=registry.gitlab.com/joern_schonhoff/dns-healthcheck:v0.1.5@sha256:abfd0c9bfbc96b4388e82004223f36e8dfd1d5846d3cb3a3d43b286e6ae8d2c8

# Pull distroless base into a named stage so it can be referenced in COPY --from
# (ARG substitution is not supported in COPY --from, only in FROM)
FROM ${DISTROLESS_IMAGE} AS distroless
FROM ${DNS_HEALTHCHECK_IMAGE} AS dns-healthcheck

# Stage 1: Compile powerdns authoritative server from source with all features enabled
FROM ${DEBIAN_BASE_IMAGE} AS builder
ARG PDNS_AUTH_VERSION
RUN test -n "${PDNS_AUTH_VERSION}" || { echo "PDNS_AUTH_VERSION build-arg is required"; exit 1; }

# Install build dependencies
ENV DEBIAN_FRONTEND=noninteractive

# LuaJIT is effectively unmaintained upstream but still patched by Debian;
# kept for significantly better performance over Lua 5.4 in packet processing rules.
# Alternative: replace libluajit-5.1-dev with lua5.4-dev and --with-lua=lua in configure.
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
		gnupg \
		libboost-all-dev \
		libcap2-bin \
		libcurl4-openssl-dev \
		libgeoip-dev \
		liblua5.4-dev \
		libluajit-5.1-dev \
		libmaxminddb-dev \
		libpq-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libtool \
		libyaml-cpp-dev \
		lua-yaml-dev \
		lua5.4 \
		luajit \
		make \
		pkg-config \
		python3-venv \
		ragel \
		vim \
		wget \
	&& apt-get clean

# Official PowerDNS signing keys — keyblock from https://doc.powerdns.com/powerdns-keyblock.asc
COPY powerdns-keyblock.asc /tmp/powerdns-keyblock.asc

WORKDIR /src

# Verify tarball against detached PGP signature before extracting
RUN gpg --import /tmp/powerdns-keyblock.asc \
    && curl -sSL https://downloads.powerdns.com/releases/pdns-${PDNS_AUTH_VERSION}.tar.bz2 -o pdns-${PDNS_AUTH_VERSION}.tar.bz2 \
	&& curl -sSL https://downloads.powerdns.com/releases/pdns-${PDNS_AUTH_VERSION}.tar.bz2.asc -o pdns-${PDNS_AUTH_VERSION}.tar.bz2.asc \
    && gpg --verify pdns-${PDNS_AUTH_VERSION}.tar.bz2.asc pdns-${PDNS_AUTH_VERSION}.tar.bz2 \
    && tar xf pdns-${PDNS_AUTH_VERSION}.tar.bz2 --strip-components=1

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

# Collect shared libraries via ldd; rewrite /lib/ -> /usr/lib/ because
# distroless has /lib as a symlink to usr/lib on Debian 13
RUN find /build -type f -executable -exec sh -c \
	'for f; do ldd "$f" 2>/dev/null | awk "/=>/ {print \$3}" ; done' sh {} + \
	| sort -u | grep -E "^/" \
	| while read src; do \
	    dest=$(echo "$src" | sed 's|^/lib/|/usr/lib/|'); \
	    mkdir -p "/runtime$(dirname $dest)"; \
	    cp -L "$src" "/runtime$dest"; \
	  done

# We also need vim and dependencies for "pdnsutil zone edit" in runtime
RUN cp -a /usr/bin/vim.basic /runtime/usr/bin/ \
	&& ldd /usr/bin/vim.basic | awk '/=>/ {print $3}' \
	| sort -u | grep -E "^/" \
	| while read src; do \
	    dest=$(echo "$src" | sed 's|^/lib/|/usr/lib/|'); \
	    mkdir -p "/runtime$(dirname $dest)"; \
	    cp -L "$src" "/runtime$dest"; \
	  done

# Preserve distroless base entries (root, nobody, nonroot) then append pdns
RUN mkdir -p /runtime/etc
COPY --from=distroless /etc/passwd /runtime/etc/passwd
COPY --from=distroless /etc/group /runtime/etc/group
RUN echo "pdns:x:1000:1000:PowerDNS user:/var/lib/pdns:/sbin/nologin" >> /runtime/etc/passwd \
    && echo "pdns:x:1000:" >> /runtime/etc/group

# Strip debug symbols from collected shared libraries to reduce image size
RUN find /runtime -type f \( -name "*.so" -o -name "*.so.*" \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

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

# Stage 2: Minimal distroless runtime — no shell, no package manager
FROM ${DISTROLESS_IMAGE} AS runtime

ARG PDNS_AUTH_VERSION

# SPDX identifier required by the OCI image-spec for org.opencontainers.image.licenses
LABEL \
	org.opencontainers.image.authors="Joern Schonhoff <joerns92@live.com>" \
    org.opencontainers.image.description="PowerDNS Authoritative Server ${PDNS_AUTH_VERSION} based on Distroless Debian 13" \
    org.opencontainers.image.licenses="GPL-2.0-only" \
    org.opencontainers.image.source="https://gitlab.com/joern_schonhoff/pdns-auth-distroless" \
    org.opencontainers.image.title="pdns-auth-distroless" \
    org.opencontainers.image.url="https://gitlab.com/joern_schonhoff/pdns-auth-distroless" \
    org.opencontainers.image.version="${PDNS_AUTH_VERSION}"
	# org.opencontainers.image.created="FILLED BY BUILD SYSTEM"
	# org.opencontainers.image.revision="FILLED BY BUILD SYSTEM"

# Copy runtime fs from builder
COPY --from=builder /runtime/ /
COPY --from=dns-healthcheck /dns-healthcheck /usr/bin/dns-healthcheck

# Expose DNS ports
EXPOSE 53/tcp 53/udp

# Run as pdns user created in /etc/passwd (UID 1000)
USER 1000:1000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
    CMD ["/usr/bin/dns-healthcheck", "--check-udp", "--check-tcp"]

ENTRYPOINT ["/usr/sbin/pdns_server"]
CMD ["--config-dir=/etc/pdns"]
