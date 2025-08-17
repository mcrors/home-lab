#!/usr/bin/env bash
set -euo pipefail

# This script is invoked by Certbot after a successful renewal for {{ cert_domain }}.
# It performs all post-renew tasks.

"{{ reload_nginx_path }}"
"{{ push_k8s_path }}"
