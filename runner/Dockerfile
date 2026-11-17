# GitHub Actions runner for the OpenNIT image build: official runner image + GitHub CLI
FROM ghcr.io/actions/actions-runner:2.338.2

USER root
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    # Volumes take over this ownership on first use
    mkdir -p /home/runner/state /home/runner/_work; \
    chown runner:runner /home/runner/state /home/runner/_work

COPY --chmod=755 entrypoint.sh /usr/local/bin/runner-entrypoint
USER runner
ENTRYPOINT ["runner-entrypoint"]
