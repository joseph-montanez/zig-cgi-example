
## Database Information

`src/config.zon.example` needs to be renamed to `src/config.zon`. Zon is like JSON but is at compile time imported. This can be changed to a runtime import, but you need to make code changes for that. This is new as of *Zig 0.14*

    .{
        .username = "db_username",
        .password = "db_password",
        .database = "db_name",
        .host = .{127, 0, 0, 1},
        .port = 3306,
    }

## Mod Rewrite

If you can run CGI outside the cgi-bin then this should work.

**.htaccess**

    Options +ExecCGI
    AddHandler cgi-script .cgi
    DirectoryIndex index.cgi

    RewriteEngine On
    RewriteBase /

    # Skip real files and dirs
    RewriteCond %{REQUEST_FILENAME} -f [OR]
    RewriteCond %{REQUEST_FILENAME} -d
    RewriteRule ^ - [L]

    # Don't rewrite already rewritten requests
    RewriteCond %{REQUEST_URI} ^/index.cgi
    RewriteRule ^ - [L]

    # Route root
    RewriteRule ^$ index.cgi [QSA,L]

    # Route everything else
    RewriteRule ^(.*)$ index.cgi/$1 [QSA,L]


## Permissions

All CGI need executable permissions so "0755". When you upload a new file you need to redo the permissions again.

## Automate Compile and Upload

### MacOS

    brew install lftp

**deploy.sh**

    #!/bin/bash

    HOST="ziggy.hosty.com"
    USER="myusername"
    PASS="mypassword"
    REMOTE_DIR="/httpdocs"
    LOCAL_FILE="zig-out/bin/zig_cgi"
    REMOTE_FILE="index.cgi"

    lftp -u "$USER","$PASS" "$HOST" <<EOF
    set ssl:verify-certificate no
    set ftp:passive-mode true
    cd $REMOTE_DIR
    put $LOCAL_FILE -o $REMOTE_FILE
    chmod 755 $REMOTE_FILE
    bye
    EOF

**bash**

    chmod +x deploy.sh
    zig build -Doptimize=Debug -Dtarget=x86_64-linux-musl && ./deploy.sh

### Windows

Download WinSCP: https://winscp.net/eng/index.php

**deploy.txt**

    open ftp://myusername:mypassword@ziggy.hosty.com
    cd /httpdocs
    put zig-out\\bin\\zig_cgi index.cgi
    chmod 755 index.cgi
    exit

**build_and_deploy.ps1**

    # Build with Zig
    #zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
    zig build -Doptimize=Debug -Dtarget=x86_64-linux-musl

    # Check exit code
    if ($LASTEXITCODE -eq 0) {
        & "C:\Program Files (x86)\WinSCP\WinSCP.com" /script=deploy.txt
    } else {
        Write-Host "Build failed with code $LASTEXITCODE"
    }

## Routes

Routes can filter for the typical HTTP verbs, so GET, POST, PATCH, PUT, DELETE. You can also have query parameters used from path appended.

**route with username parameter appeneded**
```zig
try route_list.append(.{ .method = .GET, .path = "/user/:username", .handler = &handleUserPrefix });
```

**function passed into route to use username**
```zig
fn handleUserPrefix(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    if (req.query.get("username")) |username| {
        try res.writer().print("User Path: {s}\n", .{username});
    }
}
```