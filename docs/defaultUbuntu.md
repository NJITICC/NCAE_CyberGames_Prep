`vim /etc/netpan/*.yml`

```
network:
    version: 2
    renderer: networkd
    ethernets:
        enp3s0:
            addresses:
                - 192.168.9.5/24
            routes:
                - to: default
                  via: 192.168.9.1
```

sudo netplan start