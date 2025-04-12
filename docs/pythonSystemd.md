
# Create user for Development
`useradd -r -s /bin/nologin etechUser`
`touch etechacademy.service`

#  Develop Systemd File if one does not exist
```
[Unit]
Description=etechacademy

[Service]
ExecStart=/usr/bin/python3 /var/lib/etechacademy.py
EnvironmentFile=/path/to/.env
User=etechUser
Group=etechUser
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`mv etechacademy.service /etc/systemd/system/`
