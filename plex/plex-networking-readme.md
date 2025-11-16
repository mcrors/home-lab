# Plex on Kubernetes -- Networking & Discovery Notes

This document explains **why Plex behaves the way it does**, how the
**cloud-assisted discovery** works, and why a **TCP passthrough** on
Traefik is required for official clients (iOS, tvOS, etc.).\
This is specifically tailored to the networking model used in this Helm
chart.

------------------------------------------------------------------------

## 1. How Plex Discovery Actually Works

Plex clients **do not** discover your server via LAN broadcast alone.

All official Plex apps follow this sequence:

### **1. Client → plex.tv (cloud)**

The client logs into your Plex account and fetches a list of servers you
own.

### **2. plex.tv → client (connection candidates)**

The Plex cloud returns a list of all known connection URLs for your
server, for example:

    http://192.168.1.133:32400
    http://plex.home:32400
    https://192-168-1-133.<certuuid>.plex.direct:32400
    https://<public-ip>.<certuuid>.plex.direct:32400

These come from: - What Plex itself detects in its environment\
- `customConnections` in `Preferences.xml`\
- The `ADVERTISE_*` variables (LinuxServer wrapper)\
- Plex cloud's own remote access detection

### **3. Client tests each candidate in priority order**

The app attempts (in this rough order):

1.  **LAN/local IP**
2.  **`*.plex.direct` TLS endpoints (preferred)**
3.  **Remote access**
4.  **Relay**

### **If a connection fails, the client moves on. If all fail → "Server Offline".**

------------------------------------------------------------------------

## 2. What `plex.direct` Actually Is

Plex generates unique hostnames like:

    192-168-1-133.<certuuid>.plex.direct

These encode the IP directly into the hostname.

-   Public DNS always resolves them (your DNS forwards upstream)
-   The client extracts the encoded IP anyway, so DNS isn't special
-   The server presents a **wildcard TLS cert for `*.plex.direct`**

This only works if the client can make a **raw TLS connection directly
to Plex** with no HTTP termination in-between.

This is the key point:\
**`plex.direct` requires end-to-end TLS passthrough.**

------------------------------------------------------------------------

## 3. Why Traefik Broke Everything (Before Fix)

Originally, Traefik was fronting port **32400** using normal HTTP
routing.\
Official Plex clients were trying:

    https://192-168-1-133.<uuid>.plex.direct:32400

Traefik saw that traffic and tried to treat it as **HTTPS meant for
Traefik**, not Plex.

Traefik doesn't have: - a certificate for `*.plex.direct` - a router
rule matching that hostname - a passthrough to backend TLS

So Traefik either rejected the TLS handshake or silently dropped the
request.\
The Plex apps interpreted this as **timeout → "Server Offline"**.

Browsers worked fine because they used **http://plex.home:32400**, which
matched existing Traefik HTTP ingress rules.

------------------------------------------------------------------------

## 4. The Correct Solution: Traefik TCP Passthrough for Plex

To make Plex clients work, Traefik needs to **accept connections on port
32400** and pass them **as raw TCP** to the Plex service **without
terminating TLS**.

### Requirements:

1.  Traefik must expose a dedicated entryPoint:

    ``` yaml
    ports:
      plex:
        port: 32400
        expose: true
        exposedPort: 32400
        protocol: TCP
    ```

2.  Add an `IngressRouteTCP` with TLS passthrough:

    ``` yaml
    apiVersion: traefik.containo.us/v1alpha1
    kind: IngressRouteTCP
    metadata:
      name: plex-tcp
      namespace: plex
    spec:
      entryPoints:
        - plex
      routes:
        - rule: "HostSNI(`*`)"   # can be tightened to *.plex.direct
          service:
            name: http          # <-- your Plex Service name
            port: 32400
      tls:
        passthrough: true
    ```

### What this does:

-   Traefik listens on the host's **32400**
-   Accepts any TLS SNI (or restricted to `*.plex.direct`)
-   Forwards the encrypted TCP stream to Plex
-   **Plex** terminates the TLS (because it has the wildcard cert)

This restores the expected end-to-end behavior for official clients.

------------------------------------------------------------------------

## 5. High-Level Flow After Fix

    iOS app
      → https://192-168-1-133.<uuid>.plex.direct:32400
         → Traefik entryPoint "plex" (TCP)
           → passthrough to plex:32400
             → Plex terminates TLS using *.plex.direct certificate
               → Client connects successfully

All Apple apps (iOS, iPadOS, tvOS) now work exactly as designed.

------------------------------------------------------------------------

## 6. Why Browsers Worked Even Before the Fix

Browsers were hitting:

    http://plex.home:32400/web

Your Traefik HTTP ingress routes handled this correctly because they
were based on:

-   **host:** `plex.home`
-   **port:** 32400 (HTTP)
-   **path routing:** `/`

These requests never involved plex.direct or TLS passthrough.

------------------------------------------------------------------------

## 7. Summary

-   Plex clients rely on the Plex cloud to discover servers and
    connection paths.
-   Official apps prefer encrypted `*.plex.direct` endpoints.
-   These endpoints require **raw TLS passthrough**, not HTTP proxying.
-   Without TCP passthrough, Traefik will drop or mishandle these
    connections.
-   Adding a `plex` TCP entryPoint + `IngressRouteTCP` with passthrough
    fixes all official Plex clients.

This Helm chart now sets up Plex with:

-   Standard HTTP ingress for browser usage\
-   TCP passthrough for official app usage\
-   Full compatibility with Plex cloud discovery
