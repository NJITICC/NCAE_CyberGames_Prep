# Postgres Permission Setup
## 1. Login as Postgres User

```bash
sudo -iu postgres psql
```

- Create a new User
```bash
CREATE USER `user` WITH PASSWORD 'password';
```

- Get list of database
```bash
\l
```

- Quit
```bash
\q
```

## 2. Show the default SCHEMA
```bash
SHOW search_path;
```

```bash
 search_path 
--------------
 "$user", public
(1 row)
```

In this case public would be the schema for user

## 3. Grant access to DB
```bash
GRANT CONNECT ON DATABASE db TO music_man;
GRANT USAGE ON SCHEMA public TO music_man;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO music_man;
```

## 4. Grant access to User Table
```bash
GRANT ALL PRIVILEGES ON TABLE users TO music_man;
```
## 5. Removing Users \ Security
Delete a Postgres User With dropuser Utility
```bash
sudo -u postgres dropuser <user> -e
```

Listing users in postgres terminal
```bash
\du

DROP USER <name>;
```

## Our Postgres Access:
```
[
  {
    "host": "192.168.9.7",
    "port": 5432,
    "database": "db",
    "password": "Th3Gr3atCity!",
    "username": "music_man"
  }
]
```

Remember to add to the .env file for the http server 