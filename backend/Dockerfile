FROM rust:1.93-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release --bins

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 exec \
    && useradd --uid 10001 --gid 10001 --home-dir /workspaces --no-create-home exec \
    && install -d -m 0700 -o 10001 -g 10001 /var/lib/exec/profile /workspaces
COPY --from=builder /build/target/release/exec-agent /build/target/release/exec-agent-admin /usr/local/bin/
COPY --chmod=0555 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENV HOME=/workspaces \
    EXEC_AGENT_DEFAULT_TOKEN_FILE=/var/lib/exec/profile/admin-token \
    EXEC_AGENT_HOST=127.0.0.1 \
    EXEC_AGENT_PORT=8765
USER 10001:10001
WORKDIR /workspaces
VOLUME ["/var/lib/exec/profile", "/workspaces"]
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
