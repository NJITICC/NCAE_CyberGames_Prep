# Obtain the Cert
sudo certbot --no-verify-ssl --server ca.ncaecybergames.org/acme/acme/directory

# Renewal 

`touch certbot-renewal.service`
```
[Unit]
Description=Certbot Renewal

[Service]
ExecStart=/usr/bin/certbot renew --post-hook "systemctl reload nginx" #Adjust per service
```

## Create Timer

`touch certbot-renewal.timer`

```
[Unit]
Description=Timer for Certbot Renewal

[Timer]
OnBootSec=300
OnUnitActiveSec=5m

[Install]
WantedBy=multi-user.target
```

`mv certbot-renewal.timer /etc/systemd/system/`

sudo systemctl start certbot-renewal.timer
sudo systemctl enable certbot-renewal.timer