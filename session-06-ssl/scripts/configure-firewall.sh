sudo sed -i \

    '/ufw allow 80\/tcp/a ufw allow 443\/tcp comment '"'"'HTTPS'"'"'' \

    /usr/local/bin/configure-firewall.sh
