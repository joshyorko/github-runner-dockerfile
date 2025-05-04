FROM --platform=$BUILDPLATFORM ubuntu:24.04

ARG RUNNER_VERSION="2.322.0"
ARG RUNNER_ARCH=x64

# Prevents installdependencies.sh from prompting the user and blocking the image creation
ARG DEBIAN_FRONTEND=noninteractive

# Install essential packages including CA certificates
RUN apt update -y && apt upgrade -y && useradd -m docker
RUN apt install -y --no-install-recommends \
    curl jq build-essential libssl-dev libffi-dev libicu-dev python3 python3-venv python3-dev python3-pip git unzip \
    ca-certificates openssl \
    # Network utilities for diagnostics
    iputils-ping iproute2 dnsutils

# Update CA certificates and configure git
RUN update-ca-certificates && \
    git config --system http.sslVerify true && \
    git config --system http.sslCAInfo /etc/ssl/certs/ca-certificates.crt && \
    git config --system --add safe.directory '*'

# Additional SSL configuration
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# playwright deps
RUN apt install -y libglib2.0-0t64 libnss3 libnspr4 libdbus-1-3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libxcb1 libxkbcommon0 libatspi2.0-0t64 libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2   

RUN cd /home/docker && mkdir actions-runner && cd actions-runner \
    && curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz

RUN chown -R docker:docker /home/docker/actions-runner

# Switch to the runner user
USER docker

# Set working directory
WORKDIR /home/docker/actions-runner

# Entrypoint script
# Copy start.sh and set ownership to the docker user
COPY --chown=docker:docker start.sh /home/docker/start.sh
RUN chmod +x /home/docker/start.sh

ENV NODE_VERSION=22.13.0
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
ENV NVM_DIR=/home/docker/.nvm
RUN . "$NVM_DIR/nvm.sh" && nvm install ${NODE_VERSION}
RUN . "$NVM_DIR/nvm.sh" && nvm use v${NODE_VERSION}
RUN . "$NVM_DIR/nvm.sh" && nvm alias default v${NODE_VERSION}
ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin/:${PATH}"

RUN npm install --global yarn

ENTRYPOINT ["/home/docker/start.sh"]
