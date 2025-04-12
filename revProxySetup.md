# Reverse Proxy Setup
## Run Status on etechacademy & discover what rev proxy you will using

```bash
systemctl status etechacademy
```

```bash
systemctl nginx 
```

```bash
systemctl status apache2
```

---

## Nginx
Recommended practice to create a custom configuration file for your new server block:

```bash
sudo vim /etc/nginx/sites-available/your_domain
```

```bash
server {
    listen 80;
    listen [::]:80;

    listen 443 ssl http2;

    server_name team9.ncaecybergames.org;

    ssl_certificate /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;
        
    location / {
        proxy_pass 127.0.0.1:8000;
        include proxy_params;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Replace `/path/to/fullchain.pem;` to actual file location of .pem

Enable  this configuration file by creating a link from it to the `sites-enabled` directory that Nginx reads at startup:

```bash
sudo ln -s /etc/nginx/sites-available/team9.ncaecybergames.org /etc/nginx/sites-enabled/
```

You can now test your configuration file for syntax errors:

```bash
sudo nginx -t
```

With no problems reported, restart Nginx to apply your changes:

```bash
sudo systemctl restart nginx
```

## Apache
Enable Necessary Apache Modules

```bash
sudo a2enmod proxy proxy_http
```
Modifying the Default Configuration to Enable Reverse Proxy

Open the default Apache configuration file using your preferred text editor:

```bash
sudo vim /etc/apache2/sites-available/000-default.conf
```

```bash
<VirtualHost *:80>
    ProxyPreserveHost On

    ProxyPass / http://localhost:8000/
    ProxyPassReverse / http://localhost:8000/
</VirtualHost>
<VirtualHost *:443>
    ServerName team9.ncaecybergames.org
    SSLEngine on  # or omit, default is on
    SSLCertificateFile "/path/to/www.example.com.cert"
    SSLCertificateKeyFile "/path/to/www.example.com.key"
</VirtualHost>
```

```bash
sudo systemctl restart apache2
```

## Final Thoughts
- systemctl cat etechacademy
- Make sure to write down where the certificate is coming from

# Cert Script
certbot --nginx --server https://ca.ncaecybergames.org/acme/acme/directory --no-random-sleep-on-renew

Check if md5sum = 761e8fbafabceac17680a28c82a097d2

/etc/letsencrypt/live/$domain

Link both .pem files to VirtualHost proxy