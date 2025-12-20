# syntax=docker/dockerfile:1

ARG BUILD_ARCH
ARG BUILD_FROM
# Builder stage: compile vico-cli for Linux
FROM golang:1.23-alpine AS builder

WORKDIR /src

# Copy go module files and download deps
COPY vico-cli-main/go.mod vico-cli-main/go.sum ./
RUN go mod download

# Copy the rest of the source
COPY vico-cli-main/ ./

# Build the vico-cli binary

RUN CGO_ENABLED=0 GOOS=linux GOARCH=$(echo ${BUILD_ARCH} | sed 's/armv7/arm/g' | sed 's/aarch64/arm64/g') go build -o /out/vico-cli main.go

# ---------------------------------------------------------------------
# Runtime image: Home Assistant base image for the current architecture
# ---------------------------------------------------------------------
ARG BUILD_FROM
FROM $BUILD_FROM

# Install MQTT client and jq for JSON handling
RUN apk add --no-cache mosquitto-clients jq

# Run as root for simplicity
USER root

WORKDIR /app

# Copy compiled binary from builder
COPY --from=builder /out/vico-cli /usr/local/bin/vico-cli

# Copy run script
COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
