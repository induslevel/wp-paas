# 🛡️ WP-PaaS: Zero-Trust WordPress Platform-as-a-Service

> **📖 Read the full architectural breakdown, origin story, and Step-by-Step Deployment Guide on the IndusLevel Blog:** > 👉 **[How One Hacked Website Took Down an Entire Server (And How to Build a Zero-Trust PaaS to Fix It)](https://induslevel.com/zero-trust-wordpress-paas-with-docker-cloudflare-tunnels/)**

WP-PaaS is a fully self-hosted, multi-tenant WordPress hosting architecture designed for absolute security and container isolation. It allows you to host dozens of independent WordPress sites on a single Debian/Ubuntu server **without exposing a single inbound port to the public internet.**

## ✨ Core Features

* **🔒 Zero-Trust Perimeter:** Bypasses traditional open ports (80/443). All traffic is securely routed through encrypted Cloudflare Tunnels.
* **💽 Native Disk Quotas:** Prevents runaway sites from crashing the server. Each tenant gets their own dynamically generated virtual `.img` disk with strict storage limits.
* **📦 Complete Isolation:** Every tenant runs inside their own dedicated WordPress, MariaDB, and Redis containers. If one site is compromised, the hacker cannot traverse the server.
* **🎛️ Push-Button Management:** Includes a pre-configured OliveTin UI dashboard. Scaffold new sites straight from your browser—no SSH required.

## 🏗️ Architecture Flow

```text
[Public Internet] 
       │
       ▼
[Cloudflare Edge] (WAF & DDoS Protection)
       │
       ▼ (Encrypted Outbound Tunnel)
       │
[Your Linux Server] 
   ├── cloudflared (Tunnel Daemon)
   ├── traefik (Internal Router)
   ├── olivetin (Management Dashboard)
   └── /tenants
        ├── client1.com (WP, DB, Redis Containers + 5GB .img disk)
        └── client2.com (WP, DB, Redis Containers + 5GB .img disk)
```

## 🚀 Quick Start & Deployment Guide

Because this platform relies on a Zero-Trust Cloudflare architecture, you must configure specific environment variables and Tunnel Tokens before booting the Docker containers.

For the complete, copy-and-paste setup tutorial, please read the official deployment guide:

🔗 **[Read the Step-by-Step Setup Guide Here](https://induslevel.com/zero-trust-wordpress-paas-with-docker-cloudflare-tunnels/)**

### Basic Clone Command

```bash
# Clone the repository anywhere on your server
git clone https://github.com/induslevel/wp-paas.git
cd wp-paas

# Proceed to the blog post above to configure your .env files before starting!
```

## 🤝 Contributing

Pull requests are welcome! If you have ideas for adding new features (like automated Duplicati off-site backups or Let's Encrypt fallbacks), feel free to open an issue or submit a PR.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
