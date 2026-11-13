FROM rust:1.93-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release

FROM debian:bookworm-slim
RUN groupadd --gid 10001 relay && useradd --uid 10001 --gid relay --no-create-home relay
COPY --from=builder /build/target/release/exec-relay /usr/local/bin/exec-relay
USER 10001:10001
ENV EXEC_RELAY_BIND=0.0.0.0:8787
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/exec-relay"]
