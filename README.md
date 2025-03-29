# Zig CGI Example

Its possible to run Zig on shared hosting. This must run as CGI or FastCGI, neither have implementations in Zig's core library like in Go, so you will need to write your own implementation. This project is the start of a CGI implementation / framework, it is not intented as a complete working example. If you are running any binary as CGI you normally cannot target **glibc**, so in Zig you can target **musl**. **LibC** is explictly disabled in Zig Build:

```zig
const exe = b.addExecutable(.{
    .name = "zig_cgi",
    .root_module = exe_mod,
    .optimize = optimize,
    .link_libc = false, // disabled
    .strip = true,
});
```

When you compile your application you will need to target musl:

```bash
zig build -Doptimize=Debug -Dtarget=x86_64-linux-musl -Ddeployment=prod
```

## Database Information

`src/config.zon.example` needs to be renamed to `src/config.prod.zon` and `src/config.local.zon`. Zon is like JSON but is at compile time imported. This can be changed to a runtime import, but you need to make code changes for that. This is new as of *Zig 0.14*

    .{
        .username = "db_username",
        .password = "db_password",
        .database = "db_name",
        .host = "localhost",
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

#### MacOS Watch Build

    brew install entr
    find src -name '*.zig' -o -name build.zig | entr -c zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl

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

## Context

In Zig there is comptime, this should be used but as a quick alternative you can use `anyopaque`. 

```zig
const Config = struct {
    username: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    host: [:0]const u8,
    port: u16,
};

const Context = struct {
    allocator: std.mem.Allocator,
    client: *Conn,
    config: *const Config,
};


fn handleUserPrefix(req: *http.Request, res: *http.Response, ctx_ptr: *anyopaque) !void {
    // Cast anyopaque to your own custom context
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));
    ctx.client....
}


pub fn main() !void {
    const ctx = Context{ .allocator = allocator, .client = &client, .config = &config };
}
```

## Flight

Flights can be added to load in sessions, authorize routes, enable CORS, etc. As long as the middleware returns true, it will process all middleware in the order provided. If you return false, no other middleware is execute, and the route is rejected. Flights can also be used for post route operations such as saving session data to disk or to a database.

```zig
fn authMiddleware(req: *http.Request, res: *http.Response, ctx: *anyopaque) !bool {
    _ = ctx; // Possibly use the context
    const auth_header = req.headers.get("Authorization");
    if (auth_header) |header| {
        if (std.mem.eql(u8, header, "Bearer mysecrettoken")) {
            return true;
        }
    }

    // Authorization failed
    res.status_code = .unauthorized;
    try res.writer().print("Unauthorized\n", .{});
    
    // Reject the other middleware/route
    return false;
}

pub fn main() !void {
    var auth_middleware = std.ArrayList(http.Middleware).init(allocator);
    try auth_middleware.append(&authMiddleware);
    defer auth_middleware.deinit();

    try route_list.append(.{ .method = .GET, .path = "/user/tasks", .handler = &register.handleUserTaskGet, .middleware = auth_middleware });
    try route_list.append(.{ .method = .POST, .path = "/user/tasks", .handler = &register.handleUserTaskPost, .middleware = auth_middleware });
}
```