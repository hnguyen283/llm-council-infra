# ============================================================================
# Custom PostgreSQL 16 image with Apache AGE + pgvector.
#
# Apache AGE: openCypher graph queries inside standard SQL.
# pgvector:   vector similarity search for embedding-based retrieval.
#
# Build:  docker build -t local/llm-council/postgres-age:local infra/postgres/
# ============================================================================
FROM postgres:16-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229 AS builder

RUN apk add --no-cache \
    build-base \
    clang \
    llvm \
    git \
    readline-dev \
    zlib-dev \
    flex \
    bison \
    perl

# --- pgvector v0.8.0 ---
RUN git clone --branch v0.8.0 --depth 1 \
        https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make OPTFLAGS="" with_llvm=0 \
    && make with_llvm=0 install

# --- Apache AGE release/PG16/1.5.0 ---
RUN git clone --branch release/PG16/1.5.0 --depth 1 \
        https://github.com/apache/age.git /tmp/age \
    && cd /tmp/age \
    && make with_llvm=0 \
    && make with_llvm=0 install

# --- Runtime image ---
FROM postgres:16-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229

# Copy compiled extensions from builder
COPY --from=builder /usr/local/lib/postgresql/ /usr/local/lib/postgresql/
COPY --from=builder /usr/local/share/postgresql/ /usr/local/share/postgresql/

# AGE requires shared_preload_libraries
RUN echo "shared_preload_libraries = 'age'" \
    >> /usr/local/share/postgresql/postgresql.conf.sample
